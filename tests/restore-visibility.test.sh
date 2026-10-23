#!/bin/bash
# Tests that restore() takes repo visibility from the backup metadata, driven
# through entrypoint.sh with curl, git, mc and sleep stubbed on PATH.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

# new_env <meta-kind>: meta-kind is private|public|missing|nojson|nofield
new_env() {
  clean_tmp
  WORK=$(mktemp -d)
  STUBS="$WORK/bin"
  mkdir -p "$STUBS" "$WORK/fx/repos/oscadmin/app.git" "$WORK/fx/meta"
  export STUB_LOG="$WORK/log" PAYLOAD_FILE="$WORK/payload"
  : > "$STUB_LOG"
  : > "$PAYLOAD_FILE"
  echo '[{"login":"oscadmin","email":"o@example.test","full_name":""}]' > "$WORK/fx/meta/users.json"
  case "$1" in
    private) echo '{"name":"app","private":true}' > "$WORK/fx/repos/oscadmin/app.meta.json" ;;
    public) echo '{"name":"app","private":false}' > "$WORK/fx/repos/oscadmin/app.meta.json" ;;
    nojson) echo '<html>nope</html>' > "$WORK/fx/repos/oscadmin/app.meta.json" ;;
    nofield) echo '{"name":"app"}' > "$WORK/fx/repos/oscadmin/app.meta.json" ;;
    stringval) echo '{"name":"app","private":"false"}' > "$WORK/fx/repos/oscadmin/app.meta.json" ;;
    missing) ;;
  esac
  tar -czf "$WORK/fixture.tar.gz" -C "$WORK/fx" repos meta
  export MC_FIXTURE="$WORK/fixture.tar.gz"

  cat > "$STUBS/mc" <<'STUB'
#!/bin/bash
case "$1" in
  cp) case "$2" in s3store/*) cp "$MC_FIXTURE" "$3" ;; esac ;;
esac
exit 0
STUB
  # curl: logs "METHOD URL", captures the -d payload of repo creates.
  cat > "$STUBS/curl" <<'STUB'
#!/bin/bash
method=GET; url=""; wflag=0; ofile=""; data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    -o) ofile="$2"; shift ;;
    -d) data="$2"; shift ;;
    -w) wflag=1; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
echo "$method $url" >> "$STUB_LOG"
code=201
case "$method $url" in
  "GET "*/api/v1/users/oscadmin) code=200 ;;
  "GET "*/api/v1/orgs/*) code=404 ;;
  "GET "*/api/v1/repos/*) code=404 ;;
  "POST "*/api/v1/admin/users/oscadmin/repos) printf '%s' "$data" > "$PAYLOAD_FILE" ;;
esac
[ -n "$ofile" ] && : > "$ofile"
[ "$wflag" = 1 ] && printf '%s' "$code"
exit 0
STUB
  cat > "$STUBS/git" <<'STUB'
#!/bin/bash
echo "git $*" >> "$STUB_LOG"
exit 0
STUB
  cat > "$STUBS/sleep" <<'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$STUBS"/*

  export PATH="$STUBS:$PATH"
  export GITEA_URL=https://gitea.example.test GITEA_TOKEN=dummy
  export S3_ENDPOINT=https://s3.example.test S3_ACCESS_KEY=a S3_SECRET_KEY=b
  export S3_BUCKET=backups S3_OBJECT_KEY=gitea/key.tar.gz
  export S3_READY_INTERVAL_SECONDS=1
  unset ENCRYPTION_KEY RESTORE_OVERWRITE_EXISTING
}

run_restore() {
  OUT=$(OPERATION=restore bash "$ROOT/entrypoint.sh" 2>&1)
  RC=$?
  clean_tmp
}

has() { printf '%s' "$OUT" | grep -qF -- "$1"; }
lacks() { ! has "$1"; }
private_is() { [ "$(jq -r '.private' "$PAYLOAD_FILE" 2>/dev/null)" = "$1" ]; }
rc_is() { [ "$RC" -eq "$1" ]; }
WARN="WARN: no visibility metadata for oscadmin/app, creating it private"

echo "V1 meta says private: created private, no warning"
new_env private; run_restore
expect "payload private=true" private_is true
expect "no WARN" lacks "WARN: no visibility metadata"
expect "exit 0" rc_is 0

echo "V2 meta says public: created public, no warning"
new_env public; run_restore
expect "payload private=false" private_is false
expect "no WARN" lacks "WARN: no visibility metadata"
expect "exit 0" rc_is 0

echo "V3 meta missing: created private with WARN"
new_env missing; run_restore
expect "payload private=true" private_is true
expect "WARN" has "$WARN"
expect "exit 0" rc_is 0

echo "V4 meta not JSON: created private with WARN"
new_env nojson; run_restore
expect "payload private=true" private_is true
expect "WARN" has "$WARN"
expect "exit 0" rc_is 0

echo "V5 meta without boolean private (absent, string): created private with WARN"
new_env nofield; run_restore
expect "absent: payload private=true" private_is true
expect "absent: WARN" has "$WARN"
new_env stringval; run_restore
expect "string: payload private=true" private_is true
expect "string: WARN" has "$WARN"

clean_tmp
echo
echo "passed=$PASS failed=$FAILN"
[ "$FAILN" -eq 0 ]
