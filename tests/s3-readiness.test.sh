#!/bin/bash
# Tests for wait_for_s3 and mc_cp_with_retry, driven through entrypoint.sh with stubbed tools.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRET="dummy-secret-key-do-not-leak"
GTOKEN="dummy-gitea-token-do-not-leak"
CP_FAIL_RC=9
PASS=0
FAILN=0

ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAILN=$((FAILN + 1)); echo "  FAIL $1"; }
# expect <description> <test command...>
expect() {
  local d="$1"
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}

# Error shapes are source-derived (minio-go ErrorResponse nested under error.cause.error in mc --json);
# docker was not available to capture them from the pinned mc.
AUTH_LS_OUT='{"status":"error","error":{"message":"Unable to list folder.","cause":{"message":"The Access Key Id you provided does not exist in our records.","error":{"Code":"InvalidAccessKeyId","Message":"The Access Key Id you provided does not exist in our records.","StatusCode":403}},"type":"error"}}'
NOTREADY_LS_OUT='{"status":"error","error":{"message":"Unable to list folder.","cause":{"message":"503 Service Temporarily Unavailable","error":{"Code":"","Message":"","StatusCode":503}},"type":"error"}}'
AUTH_CP_OUT='mc: <ERROR> Failed to copy `/tmp/x`. The Access Key Id you provided does not exist in our records.'
CP_503_OUT='mc: <ERROR> Failed to copy `/tmp/x`. <html><head><title>503 Service Temporarily Unavailable</title></head><body><center><h1>503 Service Temporarily Unavailable</h1></center><hr><center>nginx</center></body></html>'
MISSING_OUT='mc: <ERROR> Failed to copy `backups/key`. Object does not exist.'

clean_tmp() { rm -rf /tmp/gitea-backup.tar.gz /tmp/repos /tmp/meta; }

new_env() {
  clean_tmp
  WORK=$(mktemp -d)
  STUBS="$WORK/bin"
  mkdir -p "$STUBS"
  export STUB_LOG="$WORK/log"
  : > "$STUB_LOG"
  export STUB_DIR="$WORK"
  export MC_LS_FAIL=0 MC_CP_FAIL=0 MC_LS_MODE=notready MC_CP_MODE=503 CP_FAIL_RC
  export AUTH_LS_OUT NOTREADY_LS_OUT AUTH_CP_OUT CP_503_OUT MISSING_OUT

  # Fixture archive for restore: empty repos/ and meta/ directories.
  mkdir -p "$WORK/fx/repos" "$WORK/fx/meta"
  tar -czf "$WORK/fixture.tar.gz" -C "$WORK/fx" repos meta
  export MC_FIXTURE="$WORK/fixture.tar.gz"

  cat > "$STUBS/mc" <<'STUB'
#!/bin/bash
counter() { local f="$STUB_DIR/$1.count"; local n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$f"; echo "$n"; }
case "$1" in
  alias)
    case "$*" in
      *"--api S3v4"*) echo "mc alias set api=S3v4" >> "$STUB_LOG" ;;
      *) echo "mc alias set api=none" >> "$STUB_LOG" ;;
    esac
    exit 0 ;;
  mb) echo "mc mb" >> "$STUB_LOG"; exit 0 ;;
  --json)
    echo "mc --json ls" >> "$STUB_LOG"
    n=$(counter ls)
    if [ "$MC_LS_MODE" = "auth" ]; then echo "$AUTH_LS_OUT"; exit 1; fi
    if [ "$n" -le "$MC_LS_FAIL" ]; then echo "$NOTREADY_LS_OUT"; exit 1; fi
    exit 0 ;;
  cp)
    echo "mc cp" >> "$STUB_LOG"
    n=$(counter cp)
    if [ "$n" -le "$MC_CP_FAIL" ]; then
      case "$MC_CP_MODE" in
        auth) echo "$AUTH_CP_OUT" >&2 ;;
        missing) echo "$MISSING_OUT" >&2 ;;
        *) echo "$CP_503_OUT" >&2 ;;
      esac
      exit "$CP_FAIL_RC"
    fi
    case "$2" in
      s3store/*) cp "$MC_FIXTURE" "$3" ;;
      *) cp "$2" /dev/null ;;
    esac
    exit 0 ;;
esac
echo "mc $1" >> "$STUB_LOG"
exit 0
STUB
  cat > "$STUBS/curl" <<'STUB'
#!/bin/bash
out=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
case "$url" in
  */repos/search*) echo '{"data":[]}' ;;
  *) if [ -n "$out" ]; then echo '[]' > "$out"; else echo '[]'; fi ;;
esac
exit 0
STUB
  cat > "$STUBS/git" <<'STUB'
#!/bin/bash
exit 0
STUB
  cat > "$STUBS/sleep" <<'STUB'
#!/bin/bash
echo "sleep $1" >> "$STUB_LOG"
if [ "$1" -le 1 ]; then /bin/sleep "$1"; fi
exit 0
STUB
  chmod +x "$STUBS"/*

  export PATH="$STUBS:$PATH"
  export GITEA_URL=https://gitea.example.test GITEA_TOKEN="$GTOKEN"
  export S3_ENDPOINT=https://tenantbackups.minio-minio.auto.dev.osaas.io
  export S3_ACCESS_KEY=dummyaccess S3_SECRET_KEY="$SECRET" S3_BUCKET=backups S3_OBJECT_KEY=gitea/key.tar.gz
  export S3_READY_INTERVAL_SECONDS=1
  unset S3_READY_TIMEOUT_SECONDS ENCRYPTION_KEY
}

run_entry() { # operation
  OUT=$(OPERATION="$1" bash "$ROOT/entrypoint.sh" 2>&1)
  RC=$?
  clean_tmp
}

count() { grep -c -- "$1" "$STUB_LOG" || true; }
line_of() { grep -n -m1 -- "$1" "$STUB_LOG" | cut -d: -f1; }
has() { printf '%s' "$OUT" | grep -qF -- "$1"; }
count_is() { [ "$(count "$1")" -eq "$2" ]; }
rc_is() { [ "$RC" -eq "$1" ]; }
rc_nonzero() { [ "$RC" -ne 0 ]; }
no_leak() { ! printf '%s' "$OUT" | grep -qF -- "$SECRET" && ! printf '%s' "$OUT" | grep -qF -- "$GTOKEN"; }
ends_with() { [ "$(printf '%s\n' "$OUT" | tail -1)" = "$1" ]; }
# a's first line is before b's first line in the stub log
before() {
  local a b
  a=$(line_of "$1")
  b=$(line_of "$2")
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
# the nth 'mc --json ls' entry precedes the first 'mc cp'
ls_n_before_cp() {
  local n="$1" nth cp
  nth=$(grep -n 'mc --json ls' "$STUB_LOG" | sed -n "${n}p" | cut -d: -f1)
  cp=$(line_of 'mc cp')
  [ -n "$nth" ] && [ -n "$cp" ] && [ "$nth" -lt "$cp" ]
}
ready_lines_is() { [ "$(printf '%s\n' "$OUT" | grep -c 'S3 endpoint ready after')" -eq "$1" ]; }

echo "AC1 backup waits for a 503 endpoint, then uploads"
new_env; MC_LS_FAIL=4; run_entry backup
expect "exit 0" rc_is 0
expect "alias set with --api S3v4" count_is 'mc alias set api=S3v4' 1
expect "alias set before first ls" before 'mc alias set' 'mc --json ls'
expect "5 ls calls" count_is 'mc --json ls' 5
expect "5th ls precedes cp" ls_n_before_cp 5
expect "exactly one ready line" ready_lines_is 1
expect "Backup completed" has "Backup completed: gitea/key.tar.gz"
expect "no credential leak" no_leak

echo "AC2 restore waits, then downloads"
new_env; MC_LS_FAIL=4; run_entry restore
expect "exit 0" rc_is 0
expect "5 ls calls" count_is 'mc --json ls' 5
expect "5th ls precedes cp" ls_n_before_cp 5
expect "ends with Restore completed" ends_with "Restore completed"
expect "no credential leak" no_leak

echo "AC3 download retried with back-off"
new_env; MC_CP_FAIL=2; run_entry restore
expect "exit 0" rc_is 0
expect "3 cp calls" count_is 'mc cp' 3
expect "sleep 5 then sleep 15" before 'sleep 5' 'sleep 15'
expect "ends with Restore completed" ends_with "Restore completed"
expect "no credential leak" no_leak

echo "AC4 auth rejection: no wait, no retry"
new_env; MC_LS_MODE=auth; MC_CP_FAIL=999; MC_CP_MODE=auth; run_entry backup
expect "exit equals cp status" rc_is "$CP_FAIL_RC"
expect "1 ls call" count_is 'mc --json ls' 1
expect "warn line" has "WARN: S3 endpoint rejected the credentials"
expect "1 cp call" count_is 'mc cp' 1
expect "no Backup completed" bash -c '! printf "%s" "$0" | grep -qF "Backup completed:"' "$OUT"
expect "no credential leak" no_leak

echo "AC5 budget exhaustion proceeds to the transfer"
new_env; export S3_READY_TIMEOUT_SECONDS=2; MC_LS_FAIL=999; MC_CP_FAIL=999; run_entry backup
expect "not ready warn" has "WARN: S3 endpoint not ready after"
expect "proceeding" has "proceeding"
expect "3 cp calls" count_is 'mc cp' 3
expect "non-zero exit" rc_nonzero
expect "exit equals cp status" rc_is "$CP_FAIL_RC"
expect "no Backup completed" bash -c '! printf "%s" "$0" | grep -qF "Backup completed:"' "$OUT"
expect "no credential leak" no_leak

echo "AC6 download of a missing object is not retried"
new_env; MC_CP_FAIL=999; MC_CP_MODE=missing; run_entry restore
expect "1 cp call" count_is 'mc cp' 1
expect "non-zero exit" rc_nonzero
expect "no credential leak" no_leak

echo "AC7 AWS endpoint skips the wait"
new_env; S3_ENDPOINT=https://s3.eu-north-1.amazonaws.com; run_entry backup
expect "exit 0" rc_is 0
expect "0 ls calls" count_is 'mc --json ls' 0
expect "Backup completed" has "Backup completed:"
expect "no credential leak" no_leak

clean_tmp
echo
echo "passed=$PASS failed=$FAILN"
[ "$FAILN" -eq 0 ]
