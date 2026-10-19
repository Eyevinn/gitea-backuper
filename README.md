# gitea-backuper

OSC runner image for backing up and restoring tenant Gitea instances on [Open Source Cloud](https://osaas.io).

## Overview

`gitea-backuper` is a job-type OSC service that performs full Git mirror backups of a tenant's Gitea instance and stores them encrypted on MinIO/S3-compatible storage. It also supports restoring a Gitea instance from a previously created backup.

**Backup includes:**
- All repositories (git mirror clone)
- Per-repository metadata (description, visibility, topics, etc.)
- User and organisation lists

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `OPERATION` | Yes | `backup` or `restore` |
| `GITEA_URL` | Yes | Base URL of the Gitea instance (e.g. `https://acme-acmegit.go-gitea-gitea.auto.prod.osaas.io`) |
| `GITEA_TOKEN` | Yes | Gitea admin API token |
| `S3_ENDPOINT` | Yes | MinIO/S3 endpoint URL (e.g. `https://minio.example.com`) |
| `S3_BUCKET` | Yes | Bucket name (e.g. `backups`) |
| `S3_OBJECT_KEY` | Yes | Object key within the bucket (e.g. `gitea/my-instance/2026-05-01T12:00:00Z.tar.gz.enc`) |
| `S3_ACCESS_KEY` | Yes | MinIO/S3 access key |
| `S3_SECRET_KEY` | Yes | MinIO/S3 secret key |
| `ENCRYPTION_KEY` | No | AES-256-CBC passphrase for encrypting/decrypting the backup archive. If omitted, the archive is stored unencrypted. Must match between backup and restore runs. |
| `S3_READY_TIMEOUT_SECONDS` | No | Max seconds to wait for the S3 endpoint to answer before the transfer (default `300`). Skipped for `amazonaws.com` endpoints. On timeout the job proceeds and the transfer decides the outcome. |
| `S3_READY_INTERVAL_SECONDS` | No | Seconds between readiness probes (default `5`). |

Before every backup/restore transfer the job waits for the S3 endpoint, and `mc cp` is retried up to 3 times (5 s, then 15 s back-off; credential errors and missing objects are not retried).

## Usage on OSC

This image is available as the job service `eyevinn-gitea-backuper` on Open Source Cloud.

### Backup

```bash
osc run eyevinn-gitea-backuper \
  --Operation backup \
  --GiteaUrl https://acme-acmegit.go-gitea-gitea.auto.prod.osaas.io \
  --GiteaToken <admin-token> \
  --S3Endpoint https://minio.example.com \
  --S3Bucket backups \
  --S3ObjectKey "gitea/acme/$(date -u +%Y-%m-%dT%H:%M:%SZ).tar.gz.enc" \
  --S3AccessKey <access-key> \
  --S3SecretKey <secret-key> \
  --EncryptionKey <passphrase>
```

### Restore

```bash
osc run eyevinn-gitea-backuper \
  --Operation restore \
  --GiteaUrl https://acme-acmegit.go-gitea-gitea.auto.prod.osaas.io \
  --GiteaToken <admin-token> \
  --S3Endpoint https://minio.example.com \
  --S3Bucket backups \
  --S3ObjectKey "gitea/acme/2026-05-01T12:00:00Z.tar.gz.enc" \
  --S3AccessKey <access-key> \
  --S3SecretKey <secret-key> \
  --EncryptionKey <passphrase>
```

## Building Locally

```bash
docker build -f Dockerfile.osc -t gitea-backuper .
docker run --rm \
  -e OPERATION=backup \
  -e GITEA_URL=https://... \
  ...
  gitea-backuper
```

## Running the tests

```bash
bash tests/run.sh
```

Requires bash, tar, gzip and jq. `mc`, `curl`, `git` and `sleep` are stubbed.

## Encryption

When `ENCRYPTION_KEY` is set, the backup archive is encrypted with AES-256-CBC using `openssl enc -aes-256-cbc -salt -pbkdf2`. This matches the encryption format used by [db-backuper](https://github.com/eyevinn-osaas/db-backuper), so the same tooling can decrypt both types of backup.

## Restore Notes

- Existing users and repositories are not overwritten — conflicts are silently skipped so restore is safe to run against a partially restored instance.
- Users restored from backup are created with a random password and `must_change_password: true`.
- The built-in `oscadmin` user is skipped during user restore.
- Org repositories are created under their original organisation; user repositories fall back to the `oscadmin` user if the owner org/user does not exist yet.

## License

MIT License — see [LICENSE](LICENSE).
