#!/bin/bash
set -euo pipefail

# Required environment variables
: "${OPERATION:?OPERATION env var is required (backup or restore)}"
: "${GITEA_URL:?GITEA_URL env var is required}"
: "${GITEA_TOKEN:?GITEA_TOKEN env var is required}"
: "${S3_ENDPOINT:?S3_ENDPOINT env var is required}"
: "${S3_BUCKET:?S3_BUCKET env var is required}"
: "${S3_OBJECT_KEY:?S3_OBJECT_KEY env var is required}"
: "${S3_ACCESS_KEY:?S3_ACCESS_KEY env var is required}"
: "${S3_SECRET_KEY:?S3_SECRET_KEY env var is required}"

# Strip trailing slash from GITEA_URL
GITEA_URL="${GITEA_URL%/}"

# Extract hostname from GITEA_URL for git clone commands
GITEA_HOST=$(echo "$GITEA_URL" | sed 's|https://||' | sed 's|/.*||')

BACKUP_FILE="/tmp/gitea-backup.tar.gz"
REPOS_DIR="/tmp/repos"
META_DIR="/tmp/meta"

# Configure mc alias
# --api S3v4 makes "alias set" a local config write; without it mc probes the
# server and aborts the job (set -e) when the endpoint still answers 503.
configure_mc() {
  mc alias set s3store "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}" --api S3v4 --quiet
  wait_for_s3
}

# Returns true when the S3 target is MinIO (i.e. not AWS S3)
is_minio() {
  [[ "${S3_ENDPOINT:-}" != *"amazonaws.com"* ]]
}

# Wait until the S3 endpoint answers an authenticated request.
# Always returns 0: on timeout or rejected credentials the real transfer decides the outcome.
wait_for_s3() {
  if ! is_minio; then
    return 0
  fi
  local timeout="${S3_READY_TIMEOUT_SECONDS:-300}"
  local interval="${S3_READY_INTERVAL_SECONDS:-5}"
  local start=$SECONDS out
  echo "Waiting for S3 endpoint ${S3_ENDPOINT} ..."
  while true; do
    if out=$(mc --json ls s3store/ 2>&1); then
      echo "S3 endpoint ready after $((SECONDS - start))s"
      return 0
    fi
    if printf '%s' "$out" | grep -Eq 'AccessDenied|InvalidAccessKeyId|SignatureDoesNotMatch'; then
      echo "WARN: S3 endpoint rejected the credentials, not waiting" >&2
      return 0
    fi
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      echo "WARN: S3 endpoint not ready after $((SECONDS - start))s, proceeding" >&2
      return 0
    fi
    sleep "$interval"
  done
}

# mc cp with up to 3 attempts (back-off 5s, 15s). Credential errors and missing
# objects are not retried. Returns mc's last status after the final failure.
mc_cp_with_retry() {
  local src="$1" dst="$2" out rc=0 attempt
  local no_retry_re='Access Denied|Access Key Id you provided does not exist|signature we calculated does not match|Object does not exist'
  for attempt in 1 2 3; do
    case "$attempt" in
      2) sleep 5 ;;
      3) sleep 15 ;;
    esac
    if out=$(mc cp "$src" "$dst" 2>&1); then
      return 0
    else
      rc=$?
    fi
    printf '%s\n' "$out" >&2
    if printf '%s' "$out" | grep -Eqi "$no_retry_re"; then
      break
    fi
    echo "WARN: mc cp attempt ${attempt}/3 failed" >&2
  done
  return "$rc"
}

# Auto-create the bucket on MinIO; for AWS S3 the bucket is assumed to be pre-created
ensure_bucket_exists() {
  if is_minio; then
    mc mb --ignore-existing "s3store/${S3_BUCKET}" 2>&1 || true
  fi
}

backup() {
  echo "Starting Gitea backup..."

  mkdir -p "${REPOS_DIR}" "${META_DIR}"

  # Paginate through all repos
  page=1
  while true; do
    echo "Fetching repos page ${page}..."
    repos=$(curl -fsSL \
      -H "Authorization: Bearer ${GITEA_TOKEN}" \
      -H "Content-Type: application/json" \
      "${GITEA_URL}/api/v1/repos/search?limit=50&page=${page}" \
      | jq -r '.data // [] | .[] | "\(.owner.login)/\(.name)"')

    if [ -z "$repos" ]; then
      echo "No more repos on page ${page}, done paginating."
      break
    fi

    while IFS= read -r repo_path; do
      if [ -z "$repo_path" ]; then
        continue
      fi

      owner=$(echo "$repo_path" | cut -d'/' -f1)
      repo=$(echo "$repo_path" | cut -d'/' -f2)

      echo "Cloning mirror: ${owner}/${repo}"
      mkdir -p "${REPOS_DIR}/${owner}"
      git clone --mirror \
        "https://oscadmin:${GITEA_TOKEN}@${GITEA_HOST}/${owner}/${repo}.git" \
        "${REPOS_DIR}/${owner}/${repo}.git" 2>&1 || {
        echo "WARNING: Failed to clone ${owner}/${repo}, skipping"
        continue
      }

      echo "Fetching metadata: ${owner}/${repo}"
      curl -fsSL \
        -H "Authorization: Bearer ${GITEA_TOKEN}" \
        "${GITEA_URL}/api/v1/repos/${owner}/${repo}" \
        -o "${REPOS_DIR}/${owner}/${repo}.meta.json" || {
        echo "WARNING: Failed to fetch metadata for ${owner}/${repo}, skipping metadata"
      }
    done <<< "$repos"

    page=$((page + 1))
  done

  # Dump orgs and users
  echo "Dumping organizations..."
  curl -fsSL \
    -H "Authorization: Bearer ${GITEA_TOKEN}" \
    "${GITEA_URL}/api/v1/admin/orgs?limit=50" \
    -o "${META_DIR}/orgs.json" || echo "WARNING: Failed to fetch orgs"

  echo "Dumping users..."
  curl -fsSL \
    -H "Authorization: Bearer ${GITEA_TOKEN}" \
    "${GITEA_URL}/api/v1/admin/users?limit=50" \
    -o "${META_DIR}/users.json" || echo "WARNING: Failed to fetch users"

  # Create tar archive
  echo "Creating archive..."
  tar -czf "${BACKUP_FILE}" -C /tmp repos meta

  # Encrypt if key provided
  if [ -n "${ENCRYPTION_KEY:-}" ]; then
    echo "Encrypting backup..."
    openssl enc -aes-256-cbc -salt -pbkdf2 -k "${ENCRYPTION_KEY}" \
      -in "${BACKUP_FILE}" -out "${BACKUP_FILE}.enc"
    mv "${BACKUP_FILE}.enc" "${BACKUP_FILE}"
  fi

  # Upload to S3
  echo "Uploading to s3store/${S3_BUCKET}/${S3_OBJECT_KEY}..."
  configure_mc
  ensure_bucket_exists
  mc_cp_with_retry "${BACKUP_FILE}" "s3store/${S3_BUCKET}/${S3_OBJECT_KEY}"

  echo "Backup completed: ${S3_OBJECT_KEY}"
}

# Probe owner/repo on the target and set ACTION to one of:
#   create     repo is missing: create it, then push
#   push       repo exists but is empty: push (counted as created)
#   overwrite  repo has content and RESTORE_OVERWRITE_EXISTING=true: push --mirror
#   skip       repo has content and overwrite is not requested
#   fail       the repo could not be probed (an ERROR line has been printed)
decide_repo_action() {
  local owner="$1" repo="$2" body code empty
  body=$(mktemp)
  code=$(curl -s -o "$body" -w "%{http_code}" \
    -H "Authorization: Bearer ${GITEA_TOKEN}" \
    "${GITEA_URL}/api/v1/repos/${owner}/${repo}" || true)
  ACTION=fail
  if [ "$code" = "404" ]; then
    ACTION=create
  elif [ "$code" = "200" ] && jq -e . "$body" >/dev/null 2>&1; then
    empty=$(jq -r '.empty' "$body")
    if [ "$empty" = "true" ]; then
      ACTION=push
    elif [ "${RESTORE_OVERWRITE_EXISTING:-}" = "true" ]; then
      echo "WARN: overwriting ${owner}/${repo} (RESTORE_OVERWRITE_EXISTING=true)"
      ACTION=overwrite
    else
      echo "SKIP: ${owner}/${repo} already exists with content (set RESTORE_OVERWRITE_EXISTING=true to overwrite)"
      ACTION=skip
    fi
  else
    echo "ERROR: cannot probe ${owner}/${repo} (HTTP ${code:-000})"
  fi
  rm -f "$body"
}

restore() {
  echo "Starting Gitea restore..."

  configure_mc

  # Download from S3
  echo "Downloading from s3store/${S3_BUCKET}/${S3_OBJECT_KEY}..."
  mc_cp_with_retry "s3store/${S3_BUCKET}/${S3_OBJECT_KEY}" "${BACKUP_FILE}"

  # Decrypt if key provided
  if [ -n "${ENCRYPTION_KEY:-}" ]; then
    echo "Decrypting backup..."
    openssl enc -d -aes-256-cbc -salt -pbkdf2 -k "${ENCRYPTION_KEY}" \
      -in "${BACKUP_FILE}" -out "${BACKUP_FILE}.dec"
    mv "${BACKUP_FILE}.dec" "${BACKUP_FILE}"
  fi

  # Extract archive
  echo "Extracting archive..."
  tar -xzf "${BACKUP_FILE}" -C /tmp

  restore_failed=0
  created_count=0
  skipped_count=0
  overwritten_count=0
  failed_count=0

  # Recreate users
  if [ -f "${META_DIR}/users.json" ]; then
    echo "Recreating users..."
    user_count=$(jq 'length' "${META_DIR}/users.json")
    for i in $(seq 0 $((user_count - 1))); do
      username=$(jq -r ".[$i].login" "${META_DIR}/users.json")
      email=$(jq -r ".[$i].email" "${META_DIR}/users.json")
      full_name=$(jq -r ".[$i].full_name // \"\"" "${META_DIR}/users.json")

      # The built-in user is only skipped when it already exists on the target.
      # A target whose admin has another name lacks it, and every
      # platform-created repo is owned by it.
      if [ "$username" = "oscadmin" ]; then
        exists_code=$(curl -s -o /dev/null -w "%{http_code}" \
          -H "Authorization: Bearer ${GITEA_TOKEN}" \
          "${GITEA_URL}/api/v1/users/${username}")
        if [ "$exists_code" = "200" ]; then
          echo "Skipping built-in user: ${username}"
          continue
        fi
      fi

      echo "Creating user: ${username}"
      http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${GITEA_TOKEN}" \
        -H "Content-Type: application/json" \
        "${GITEA_URL}/api/v1/admin/users" \
        -d "{
          \"username\": \"${username}\",
          \"email\": \"${email}\",
          \"full_name\": \"${full_name}\",
          \"password\": \"$(openssl rand -hex 16)\",
          \"must_change_password\": true,
          \"send_notify\": false,
          \"source_id\": 0,
          \"login_name\": \"${username}\"
        }")

      if [ "$http_code" = "422" ] || [ "$http_code" = "409" ]; then
        echo "User ${username} already exists, skipping"
      elif [ "$http_code" != "201" ]; then
        echo "ERROR: Failed to create user ${username} (HTTP ${http_code})"
        restore_failed=1
      fi
    done
  fi

  # Restore repos from mirrors
  echo "Restoring repositories..."
  while read -r mirror_path; do
    # Path format: /tmp/repos/owner/repo.git
    relative="${mirror_path#${REPOS_DIR}/}"
    owner=$(dirname "$relative")
    repo=$(basename "$relative" .git)

    echo "Restoring repo: ${owner}/${repo}"

    # Create the repo for its owner, never under the token owner.
    # Org owners use the org endpoint, user owners the admin endpoint.
    org_code=$(curl -s -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer ${GITEA_TOKEN}" \
      "${GITEA_URL}/api/v1/orgs/${owner}")
    if [ "$org_code" = "200" ]; then
      create_url="${GITEA_URL}/api/v1/org/${owner}/repos"
    else
      create_url="${GITEA_URL}/api/v1/admin/users/${owner}/repos"
    fi

    # Probe the target first: a repo that already has content is never
    # overwritten unless RESTORE_OVERWRITE_EXISTING=true.
    decide_repo_action "${owner}" "${repo}"
    if [ "$ACTION" = "create" ]; then
      # Visibility comes from the backup metadata; anything unreadable means private.
      meta_file="${REPOS_DIR}/${owner}/${repo}.meta.json"
      repo_private=$(jq -r 'if (.private | type) == "boolean" then (.private | tostring) else "invalid" end' \
        "${meta_file}" 2>/dev/null || true)
      if [ "$repo_private" != "true" ] && [ "$repo_private" != "false" ]; then
        echo "WARN: no visibility metadata for ${owner}/${repo}, creating it private"
        repo_private=true
      fi
      http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${GITEA_TOKEN}" \
        -H "Content-Type: application/json" \
        "${create_url}" \
        -d "{
          \"name\": \"${repo}\",
          \"auto_init\": false,
          \"private\": ${repo_private}
        }" || true)

      if [ "$http_code" = "409" ]; then
        # Created by someone else after our probe: decide again on the real state.
        decide_repo_action "${owner}" "${repo}"
        if [ "$ACTION" = "create" ]; then
          echo "ERROR: ${owner}/${repo}: create returned 409 but the repo is still missing"
          ACTION=fail
        fi
      elif [ "$http_code" != "201" ]; then
        echo "ERROR: ${owner}/${repo}: failed to create repo (HTTP ${http_code})"
        ACTION=fail
      fi
    fi

    case "$ACTION" in
      skip)
        skipped_count=$((skipped_count + 1))
        continue
        ;;
      fail)
        failed_count=$((failed_count + 1))
        restore_failed=1
        continue
        ;;
    esac

    # Push mirror
    if git -C "${mirror_path}" push --mirror \
      "https://oscadmin:${GITEA_TOKEN}@${GITEA_HOST}/${owner}/${repo}.git" 2>&1; then
      if [ "$ACTION" = "overwrite" ]; then
        overwritten_count=$((overwritten_count + 1))
      else
        created_count=$((created_count + 1))
      fi
    else
      echo "ERROR: ${owner}/${repo}: failed to push mirror"
      failed_count=$((failed_count + 1))
      restore_failed=1
    fi
  done < <(find "${REPOS_DIR}" -name "*.git" -type d)

  echo "Restore summary: created=${created_count} skipped=${skipped_count} overwritten=${overwritten_count} failed=${failed_count}"

  if [ "$restore_failed" -ne 0 ]; then
    echo "ERROR: Restore finished with failures"
    return 1
  fi

  echo "Restore completed"
}

case "${OPERATION}" in
  backup)
    backup
    ;;
  restore)
    restore
    ;;
  *)
    echo "ERROR: Unknown OPERATION '${OPERATION}'. Must be 'backup' or 'restore'."
    exit 1
    ;;
esac
