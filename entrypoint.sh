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
configure_mc() {
  mc alias set s3store "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}" --quiet
}

# Returns true when the S3 target is MinIO (i.e. not AWS S3)
is_minio() {
  [[ "${S3_ENDPOINT:-}" != *"amazonaws.com"* ]]
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
  mc cp "${BACKUP_FILE}" "s3store/${S3_BUCKET}/${S3_OBJECT_KEY}"

  echo "Backup completed: ${S3_OBJECT_KEY}"
}

restore() {
  echo "Starting Gitea restore..."

  configure_mc

  # Download from S3
  echo "Downloading from s3store/${S3_BUCKET}/${S3_OBJECT_KEY}..."
  mc cp "s3store/${S3_BUCKET}/${S3_OBJECT_KEY}" "${BACKUP_FILE}"

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

  # Recreate users
  if [ -f "${META_DIR}/users.json" ]; then
    echo "Recreating users..."
    user_count=$(jq 'length' "${META_DIR}/users.json")
    for i in $(seq 0 $((user_count - 1))); do
      username=$(jq -r ".[$i].login" "${META_DIR}/users.json")
      email=$(jq -r ".[$i].email" "${META_DIR}/users.json")
      full_name=$(jq -r ".[$i].full_name // \"\"" "${META_DIR}/users.json")

      if [ "$username" = "oscadmin" ]; then
        echo "Skipping built-in user: ${username}"
        continue
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
        echo "WARNING: Failed to create user ${username} (HTTP ${http_code}), skipping"
      fi
    done
  fi

  # Restore repos from mirrors
  echo "Restoring repositories..."
  find "${REPOS_DIR}" -name "*.git" -type d | while read -r mirror_path; do
    # Derive owner and repo name from path
    # Path format: /tmp/repos/owner/repo.git
    relative="${mirror_path#${REPOS_DIR}/}"
    owner=$(dirname "$relative")
    repo=$(basename "$relative" .git)

    echo "Restoring repo: ${owner}/${repo}"

    # Determine if this is an org repo or user repo
    # Try to create under the owner; fall back to current user
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST \
      -H "Authorization: Bearer ${GITEA_TOKEN}" \
      -H "Content-Type: application/json" \
      "${GITEA_URL}/api/v1/org/${owner}/repos" \
      -d "{
        \"name\": \"${repo}\",
        \"auto_init\": false,
        \"private\": false
      }")

    if [ "$http_code" = "404" ]; then
      # org not found, try user endpoint
      http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${GITEA_TOKEN}" \
        -H "Content-Type: application/json" \
        "${GITEA_URL}/api/v1/user/repos" \
        -d "{
          \"name\": \"${repo}\",
          \"auto_init\": false,
          \"private\": false
        }")
    fi

    if [ "$http_code" = "409" ] || [ "$http_code" = "422" ]; then
      echo "Repo ${owner}/${repo} already exists, pushing anyway"
    elif [ "$http_code" != "201" ]; then
      echo "WARNING: Failed to create repo ${owner}/${repo} (HTTP ${http_code})"
    fi

    # Push mirror
    (
      cd "${mirror_path}"
      git push --mirror \
        "https://oscadmin:${GITEA_TOKEN}@${GITEA_HOST}/${owner}/${repo}.git" \
        2>&1 || echo "WARNING: Failed to push mirror for ${owner}/${repo}"
    )
  done

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
