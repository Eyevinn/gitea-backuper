#!/bin/bash
# Tests for the restore guard against existing repos and the summary line, driven
# through entrypoint.sh with curl, git, mc and sleep stubbed on PATH.
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
  export PUSH_FAIL_MATCH="" USER_CREATE_FAIL=0 PROBE_MAP="" CREATE_CODE=201
  unset RESTORE_OVERWRITE_EXISTING

  cat > "$STUBS/mc" <<'STUB'
#!/bin/bash
case "$1" in
  cp) case "$2" in s3store/*) cp "$MC_FIXTURE" "$3" ;; esac ;;
esac
exit 0
STUB
  # curl: logs "METHOD URL"; honours -o FILE and prints an HTTP code when -w is used.
  # PROBE_MAP="owner/repo=content|empty|nofield|nojson|500|404 ..." drives GET /repos/owner/repo.
  cat > "$STUBS/curl" <<'STUB'
#!/bin/bash
method=GET; url=""; wflag=0; ofile=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    -o) ofile="$2"; shift ;;
    -w) wflag=1; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
echo "$method $url" >> "$STUB_LOG"
code=201
body=""
case "$method $url" in
  "GET "*/api/v1/users/oscadmin) code=200 ;;
  "GET "*/api/v1/orgs/acme) code=200 ;;
  "GET "*/api/v1/orgs/*) code=404 ;;
  "GET "*/api/v1/repos/*)
    key="${url#*/api/v1/repos/}"
    mode=404
    for kv in $PROBE_MAP; do [ "${kv%%=*}" = "$key" ] && mode="${kv#*=}"; done
    case "$mode" in
      content) code=200; body='{"empty":false}' ;;
      empty) code=200; body='{"empty":true}' ;;
      nofield) code=200; body='{"name":"x"}' ;;
      nojson) code=200; body='<html>nope</html>' ;;
      500) code=500 ;;
      *) code=404 ;;
    esac ;;
  "POST "*/api/v1/admin/users) [ "$USER_CREATE_FAIL" = 1 ] && code=500 ;;
  "POST "*) code="$CREATE_CODE" ;;
esac
[ -n "$ofile" ] && printf '%s' "$body" > "$ofile"
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
last_is() { [ "$(printf '%s' "$OUT" | tail -n 1)" = "$1" ]; }

ALL_CONTENT="oscadmin/app=content oscadmin/lib=content acme/tool=content"

echo "G1 existing repos with content, no flag: nothing pushed, skipped, exit 0"
new_env; PROBE_MAP="$ALL_CONTENT"; run_restore
expect "exit 0" rc_is 0
expect "no push" not_logged 'push --mirror'
expect "no org create" not_logged 'POST https://gitea.example.test/api/v1/org'
expect "SKIP line" has "SKIP: oscadmin/app already exists with content"
expect "summary" has "Restore summary: created=0 skipped=3 overwritten=0 failed=0"
expect "Restore completed last" last_is "Restore completed"

echo "G2 existing with content, flag true: overwritten"
new_env; PROBE_MAP="$ALL_CONTENT"
RESTORE_OVERWRITE_EXISTING=true run_restore
expect "exit 0" rc_is 0
expect "pushed" count_is 'push --mirror' 3
expect "WARN line" has "WARN: overwriting oscadmin/app (RESTORE_OVERWRITE_EXISTING=true)"
expect "summary" has "Restore summary: created=0 skipped=0 overwritten=3 failed=0"
expect "Restore completed last" last_is "Restore completed"

for v in false yes TRUE 1; do
  echo "G3 flag '$v' behaves as unset"
  new_env; PROBE_MAP="$ALL_CONTENT"
  RESTORE_OVERWRITE_EXISTING=$v run_restore
  expect "no push" not_logged 'push --mirror'
  expect "skipped=3" has "skipped=3 overwritten=0"
done

echo "G4 existing but empty repo: pushed, counted created, not created again"
new_env; PROBE_MAP="oscadmin/app=empty oscadmin/lib=empty acme/tool=empty"; run_restore
expect "exit 0" rc_is 0
expect "pushed" count_is 'push --mirror' 3
expect "no org create" not_logged 'POST https://gitea.example.test/api/v1/org'
expect "no user-repo create" not_logged 'POST https://gitea.example.test/api/v1/admin/users/oscadmin/repos'
expect "summary" has "Restore summary: created=3 skipped=0 overwritten=0 failed=0"

echo "G5 missing repos (404): created then pushed"
new_env; PROBE_MAP=""; run_restore
expect "exit 0" rc_is 0
expect "org create" logged 'POST https://gitea.example.test/api/v1/org/acme/repos'
expect "user create" logged 'POST https://gitea.example.test/api/v1/admin/users/oscadmin/repos'
expect "pushed" count_is 'push --mirror' 3
expect "summary" has "Restore summary: created=3 skipped=0 overwritten=0 failed=0"
expect "Restore completed last" last_is "Restore completed"

echo "G6 probe error (500): ERROR, no push, non-zero"
new_env; PROBE_MAP="oscadmin/app=500 oscadmin/lib=content acme/tool=content"; run_restore
expect "non-zero" rc_nonzero
expect "ERROR line" has "ERROR: cannot probe oscadmin/app (HTTP 500)"
expect "failed repo not pushed" not_logged '/oscadmin/app.git'
expect "summary" has "skipped=2 overwritten=0 failed=1"
expect "no Restore completed" lacks "Restore completed"

echo "G7 non-JSON body is a probe failure, missing field means has content"
new_env; PROBE_MAP="oscadmin/app=nojson oscadmin/lib=nofield acme/tool=content"; run_restore
expect "non-zero" rc_nonzero
expect "non-JSON ERROR" has "ERROR: cannot probe oscadmin/app"
expect "missing field: skipped" has "SKIP: oscadmin/lib already exists with content"
expect "nothing pushed" not_logged 'push --mirror'

echo "G8 push fails on a created repo: non-zero"
new_env; PUSH_FAIL_MATCH="/oscadmin/app.git"; run_restore
expect "non-zero" rc_nonzero
expect "ERROR line" has "ERROR: oscadmin/app: failed to push mirror"
expect "summary" has "Restore summary: created=2 skipped=0 overwritten=0 failed=1"
expect "no Restore completed" lacks "Restore completed"

echo "G9 create returns 409 although the probe said missing: ERROR, non-zero"
new_env; CREATE_CODE=409; PROBE_MAP=""; run_restore
expect "ERROR line" has "ERROR: acme/tool: create returned 409"
expect "non-zero" rc_nonzero
expect "no push" not_logged 'push --mirror'

echo "G10 user create fails (HTTP 500): non-zero, no Restore completed"
new_env; USER_CREATE_FAIL=1; PROBE_MAP="$ALL_CONTENT"; run_restore
expect "non-zero" rc_nonzero
expect "ERROR names user" has "ERROR: Failed to create user alice"
expect "no Restore completed" lacks "Restore completed"

echo "G11 mixed archive: counts add up"
new_env; PROBE_MAP="oscadmin/app=content oscadmin/lib=empty acme/tool=404"; run_restore
expect "exit 0" rc_is 0
expect "summary" has "Restore summary: created=2 skipped=1 overwritten=0 failed=0"

clean_tmp
echo
echo "passed=$PASS failed=$FAILN"
[ "$FAILN" -eq 0 ]
