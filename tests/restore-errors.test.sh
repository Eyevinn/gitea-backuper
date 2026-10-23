#!/bin/bash
# Tests for the restore ERR trap: every implicit failure path prints exactly one
# "ERROR: restore failed during <step>" line and keeps its exit status.
# Driven through entrypoint.sh with stubbed tools (same approach as s3-readiness.test.sh).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTRY="${ENTRYPOINT:-$ROOT/entrypoint.sh}"
SECRET="dummy-secret-key-do-not-leak"
GTOKEN="dummy-gitea-token-do-not-leak"
ENCKEY="dummy-encryption-key-do-not-leak"
ALIAS_RC=7
CP_RC=9
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

# new_env <fixture>: ok | corrupt-archive | corrupt-users | encrypted | repo
new_env() {
  clean_tmp
  WORK=$(mktemp -d)
  STUBS="$WORK/bin"
  mkdir -p "$STUBS" "$WORK/fx/repos" "$WORK/fx/meta"
  export STUB_DIR="$WORK" ALIAS_RC CP_RC
  export MC_ALIAS_FAIL=0 MC_CP_FAIL=0 CURL_CODE=200

  case "$1" in
    corrupt-users) echo '{not json' > "$WORK/fx/meta/users.json" ;;
    repo) mkdir -p "$WORK/fx/repos/owner/repo.git" ;;
  esac
  tar -czf "$WORK/fixture.tar.gz" -C "$WORK/fx" repos meta
  case "$1" in
    corrupt-archive) echo 'this is not a gzip archive' > "$WORK/fixture.tar.gz" ;;
    encrypted)
      openssl enc -aes-256-cbc -salt -pbkdf2 -k "$ENCKEY" \
        -in "$WORK/fixture.tar.gz" -out "$WORK/fixture.enc"
      mv "$WORK/fixture.enc" "$WORK/fixture.tar.gz"
      ;;
  esac
  export MC_FIXTURE="$WORK/fixture.tar.gz"

  cat > "$STUBS/mc" <<'STUB'
#!/bin/bash
case "$1" in
  alias) [ "$MC_ALIAS_FAIL" = 1 ] && { echo "mc: <ERROR> alias failed" >&2; exit "$ALIAS_RC"; }; exit 0 ;;
  cp)
    if [ "$MC_CP_FAIL" = 1 ]; then echo "mc: <ERROR> Failed to copy. 503 Service Unavailable" >&2; exit "$CP_RC"; fi
    cp "$MC_FIXTURE" "$3"; exit 0 ;;
esac
exit 0
STUB
  cat > "$STUBS/curl" <<'STUB'
#!/bin/bash
# prints CURL_CODE when asked for the status code (-w), else an empty JSON list
for a in "$@"; do
  if [ "$a" = "%{http_code}" ]; then printf '%s' "$CURL_CODE"; exit 0; fi
done
echo '[]'
exit 0
STUB
  printf '#!/bin/bash\nexit 0\n' > "$STUBS/git"
  printf '#!/bin/bash\nexit 0\n' > "$STUBS/sleep"
  chmod +x "$STUBS"/*

  export PATH="$STUBS:$PATH"
  export GITEA_URL=https://gitea.example.test GITEA_TOKEN="$GTOKEN"
  export S3_ENDPOINT=https://s3.eu-north-1.amazonaws.com
  export S3_ACCESS_KEY=dummyaccess S3_SECRET_KEY="$SECRET" S3_BUCKET=backups S3_OBJECT_KEY=gitea/key.tar.gz
  unset ENCRYPTION_KEY RESTORE_OVERWRITE_EXISTING
}

run_entry() {
  OUT=$(OPERATION="$1" bash "$ENTRY" 2>&1)
  RC=$?
  clean_tmp
}

has() { printf '%s' "$OUT" | grep -qF -- "$1"; }
rc_is() { [ "$RC" -eq "$1" ]; }
trap_lines_is() { [ "$(printf '%s\n' "$OUT" | grep -c '^ERROR: restore failed during')" -eq "$1" ]; }
error_lines_is() { [ "$(printf '%s\n' "$OUT" | grep -cE '^\s*ERROR\b')" -eq "$1" ]; }
last_error_is() { [ "$(printf '%s\n' "$OUT" | grep -E '^ERROR:' | tail -1)" = "$1" ]; }
no_leak() {
  ! printf '%s' "$OUT" | grep -qF -- "$SECRET" && ! printf '%s' "$OUT" | grep -qF -- "$GTOKEN" \
    && ! printf '%s' "$OUT" | grep -qF -- "$ENCKEY" && ! printf '%s' "$OUT" | grep -qF -- "dummyaccess"
}
step_is() { # exactly one trap line, naming the step
  trap_lines_is 1 && error_lines_is 1 && last_error_is "ERROR: restore failed during $1"
}

echo "mc alias set fails"
new_env ok; MC_ALIAS_FAIL=1; run_entry restore
expect "exit status of the failing command" rc_is "$ALIAS_RC"
expect "one line, step configure S3" step_is "configure S3"
expect "no secret in output" no_leak

echo "download fails after retries"
new_env ok; MC_CP_FAIL=1; run_entry restore
expect "exit status of mc cp" rc_is "$CP_RC"
expect "one line, step download" step_is "download"
expect "no secret in output" no_leak

echo "wrong ENCRYPTION_KEY"
new_env encrypted; ENCRYPTION_KEY="wrong-$ENCKEY"; export ENCRYPTION_KEY; run_entry restore
expect "non-zero exit" bash -c '[ "$0" -ne 0 ]' "$RC"
expect "one line, step decrypt" step_is "decrypt"
expect "no secret in output" no_leak

echo "right ENCRYPTION_KEY"
new_env encrypted; ENCRYPTION_KEY="$ENCKEY"; export ENCRYPTION_KEY; run_entry restore
expect "exit 0" rc_is 0
expect "Restore completed" has "Restore completed"
expect "no ERROR line" error_lines_is 0

echo "corrupt archive"
new_env corrupt-archive; run_entry restore
expect "non-zero exit" bash -c '[ "$0" -ne 0 ]' "$RC"
expect "one line, step extract" step_is "extract"
expect "no secret in output" no_leak

echo "corrupt users.json"
new_env corrupt-users; run_entry restore
expect "non-zero exit" bash -c '[ "$0" -ne 0 ]' "$RC"
expect "one line, step users" step_is "users"
expect "no secret in output" no_leak

echo "explicit ERROR already printed: no second line, generic line stays last"
new_env repo; CURL_CODE=500; run_entry restore
expect "exit 1" rc_is 1
expect "no trap line" trap_lines_is 0
expect "specific line printed" has "ERROR: cannot probe owner/repo (HTTP 500)"
expect "ends with generic line" last_error_is "ERROR: Restore finished with failures"
expect "no secret in output" no_leak

echo "success path"
new_env ok; run_entry restore
expect "exit 0" rc_is 0
expect "Restore completed" has "Restore completed"
expect "summary line" has "Restore summary: created=0 skipped=0 overwritten=0 failed=0"
expect "no ERROR line" error_lines_is 0
expect "no failed=[1-9]" bash -c '! printf "%s" "$0" | grep -qE "failed=[1-9]"' "$OUT"

clean_tmp
echo
echo "passed=$PASS failed=$FAILN"
[ "$FAILN" -eq 0 ]
