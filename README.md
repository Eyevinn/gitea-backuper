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
| `RESTORE_OVERWRITE_EXISTING` | No | Restore only. Set to exactly `true` to `git push --mirror` over repositories that already exist on the target with content (this force-resets them to the snapshot and deletes newer branches). Any other value, or unset, leaves such repositories untouched. |

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

- Existing users are not overwritten. Each repository in the archive is probed on the target first: a missing repo is created and pushed, an empty repo is pushed, and a repo that already has content is skipped with a `SKIP:` line, so restore is safe to re-run and never rewrites newer live state. Set `RESTORE_OVERWRITE_EXISTING=true` to overwrite such repos with `git push --mirror` (a `WARN:` line is printed per repo).
- The job prints `Restore summary: created=<n> skipped=<n> overwritten=<n> failed=<n>`. A skipped repo is not a failure. Any failed user create, repo probe, repo create or push prints an `ERROR:` line and the job exits non-zero; only a run without failures ends with `Restore completed`.
- On OSC the job schema (`eyevinn-gitea-backuper`) exposes `Operation, GiteaUrl, GiteaToken, S3Endpoint, S3Bucket, S3ObjectKey, S3AccessKey, S3SecretKey, S3Region, EncryptionKey` and not `RESTORE_OVERWRITE_EXISTING`, so the default (never overwrite) applies. To reset one repo to the snapshot, delete that repo in Gitea and run the restore, which recreates it.
- Repository visibility is restored from the backup metadata (`private` in `repos/<owner>/<repo>.meta.json`). A repo without readable metadata is created private and a `WARN: no visibility metadata for <owner>/<repo>, creating it private` line is printed. Repos that already exist are not changed.
- Users restored from backup are created with a random password and `must_change_password: true`.
- The built-in `oscadmin` user is skipped during user restore.
- Org repositories are created under their original organisation; user repositories fall back to the `oscadmin` user if the owner org/user does not exist yet.

## License

MIT License — see [LICENSE](LICENSE).
