#!/bin/bash
# Tests for the restore owner/repo path and exit code, driven through entrypoint.sh
# with curl, git, mc and sleep stubbed on PATH.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GTOKEN="dummy-gitea-token-do-not-leak"
PASS=0
FAILN=0

ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAILN=$((FAILN + 1)); echo "  FAIL $1"; }
expect() {
  local d="$1"
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}

clean_tmp() { rm -rf /tmp/gitea-backup.tar.gz /tmp/repos /tmp/meta; }

new_env() {
  clean_tmp
  WORK=$(mktemp -d)
  STUBS="$WORK/bin"
  mkdir -p "$STUBS"
  export STUB_LOG="$WORK/log"
  : > "$STUB_LOG"

  # Fixture: repos owned by oscadmin (user), acme (org); users.json has oscadmin and alice.
  mkdir -p "$WORK/fx/repos/oscadmin/app.git" "$WORK/fx/repos/oscadmin/lib.git" \
    "$WORK/fx/repos/acme/tool.git" "$WORK/fx/meta"
  cat > "$WORK/fx/meta/users.json" <<'JSON'
[{"login":"oscadmin","email":"oscadmin@example.test","full_name":""},
 {"login":"alice","email":"alice@example.test","full_name":"Alice"}]
JSON
  tar -czf "$WORK/fixture.tar.gz" -C "$WORK/fx" repos meta
  export MC_FIXTURE="$WORK/fixture.tar.gz"
  export OSCADMIN_EXISTS=0 PUSH_FAIL_MATCH="" CREATE_FAIL_MATCH=""

  cat > "$STUBS/mc" <<'STUB'
#!/bin/bash
case "$1" in
  cp) case "$2" in s3store/*) cp "$MC_FIXTURE" "$3" ;; esac ;;
esac
exit 0
STUB
  # curl: logs "METHOD URL"; prints an HTTP code when -w is used.
  cat > "$STUBS/curl" <<'STUB'
#!/bin/bash
method=GET; url=""; wflag=0
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    -w) wflag=1; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
echo "$method $url" >> "$STUB_LOG"
code=201
case "$method $url" in
  "GET "*/api/v1/users/oscadmin) [ "$OSCADMIN_EXISTS" = 1 ] && code=200 || code=404 ;;
  "GET "*/api/v1/orgs/acme) code=200 ;;
  "GET "*/api/v1/orgs/*) code=404 ;;
  "GET "*/api/v1/repos/*) code=404 ;;
  "POST "*) [ -n "$CREATE_FAIL_MATCH" ] && case "$url" in *"$CREATE_FAIL_MATCH"*) code=500 ;; esac ;;
esac
[ "$wflag" = 1 ] && printf '%s' "$code"
exit 0
STUB
  # git: logs the push target; fails when the URL matches PUSH_FAIL_MATCH.
  cat > "$STUBS/git" <<'STUB'
#!/bin/bash
echo "git $*" >> "$STUB_LOG"
if [ -n "$PUSH_FAIL_MATCH" ]; then
  case "$*" in *"$PUSH_FAIL_MATCH"*) echo "remote: push rejected" >&2; exit 1 ;; esac
fi
exit 0
STUB
  cat > "$STUBS/sleep" <<'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$STUBS"/*

  export PATH="$STUBS:$PATH"
  export GITEA_URL=https://gitea.example.test GITEA_TOKEN="$GTOKEN"
  export S3_ENDPOINT=https://s3.example.test S3_ACCESS_KEY=a S3_SECRET_KEY=b
  export S3_BUCKET=backups S3_OBJECT_KEY=gitea/key.tar.gz
  export S3_READY_INTERVAL_SECONDS=1
  unset ENCRYPTION_KEY
}

run_restore() {
  OUT=$(OPERATION=restore bash "$ROOT/entrypoint.sh" 2>&1)
  RC=$?
  clean_tmp
}

has() { printf '%s' "$OUT" | grep -qF -- "$1"; }
lacks() { ! has "$1"; }
logged() { grep -qF -- "$1" "$STUB_LOG"; }
not_logged() { ! logged "$1"; }
rc_is() { [ "$RC" -eq "$1" ]; }
rc_nonzero() { [ "$RC" -ne 0 ]; }
count_is() { [ "$(grep -cF -- "$1" "$STUB_LOG" || true)" -eq "$2" ]; }
count_line_is() { [ "$(grep -cxF -- "$1" "$STUB_LOG" || true)" -eq "$2" ]; }
no_leak() { ! has "$GTOKEN" || printf '%s' "$OUT" | grep -F "$GTOKEN" | grep -qv 'ERROR'; }

echo "AC1 missing oscadmin is created, repos created for their owner"
new_env; OSCADMIN_EXISTS=0; run_restore
expect "exit 0" rc_is 0
expect "oscadmin user created" count_line_is 'POST https://gitea.example.test/api/v1/admin/users' 2
expect "Creating user: oscadmin" has "Creating user: oscadmin"
expect "no skip of oscadmin" lacks "Skipping built-in user"
expect "user repo via admin endpoint" logged 'POST https://gitea.example.test/api/v1/admin/users/oscadmin/repos'
expect "org repo via org endpoint" logged 'POST https://gitea.example.test/api/v1/org/acme/repos'
expect "never created under token owner" not_logged '/api/v1/user/repos'
expect "oscadmin app pushed" logged '/oscadmin/app.git'
expect "oscadmin lib pushed" logged '/oscadmin/lib.git'
expect "acme tool pushed" logged '/acme/tool.git'
expect "Restore completed" has "Restore completed"

echo "AC2 existing oscadmin is skipped, no new oscadmin user"
new_env; OSCADMIN_EXISTS=1; run_restore
expect "exit 0" rc_is 0
expect "skipped built-in user" has "Skipping built-in user: oscadmin"
expect "only alice created" count_line_is 'POST https://gitea.example.test/api/v1/admin/users' 1
expect "all pushed" count_is 'push --mirror' 3
expect "Restore completed" has "Restore completed"

echo "AC3 failing push: continue, ERROR with path, non-zero exit"
new_env; PUSH_FAIL_MATCH="/oscadmin/app.git"; run_restore
expect "non-zero exit" rc_nonzero
expect "ERROR names owner/repo" has "ERROR: oscadmin/app: failed to push mirror"
expect "remaining repos still pushed" logged '/acme/tool.git'
expect "other oscadmin repo still pushed" logged '/oscadmin/lib.git'
expect "no Restore completed" lacks "Restore completed"

echo "AC3 failing repo create: continue, ERROR with path, non-zero exit"
new_env; CREATE_FAIL_MATCH="/org/acme/repos"; run_restore
expect "non-zero exit" rc_nonzero
expect "ERROR names owner/repo" has "ERROR: acme/tool: failed to create repo"
expect "failed repo not pushed" not_logged '/acme/tool.git'
expect "other repos pushed" count_is 'push --mirror' 2
expect "no Restore completed" lacks "Restore completed"

echo "AC3 failing owner create: ERROR, non-zero exit"
new_env; CREATE_FAIL_MATCH="/api/v1/admin/users"; run_restore
expect "non-zero exit" rc_nonzero
expect "ERROR names user" has "ERROR: Failed to create user oscadmin"
expect "no Restore completed" lacks "Restore completed"

clean_tmp
echo
echo "passed=$PASS failed=$FAILN"
[ "$FAILN" -eq 0 ]
