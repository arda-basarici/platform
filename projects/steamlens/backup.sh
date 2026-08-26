#!/usr/bin/env bash
# Nightly backup of the steamlens store — snapshot, verify, ship, prune.
#
# The app's whole durable state is one SQLite file (serve.db: response archive,
# ledger, journals, reports), so the backup is: take a consistent snapshot with
# sqlite3 .backup (WAL-aware, safe against concurrent writers — never a raw
# copy of a live db), integrity-check it BEFORE shipping (an unverified upload
# of a corrupt db preserves the corruption, not the data), gzip, upload to
# Drive, prune to the retention scheme (7 daily + 4 weekly).
#
# Deliberately excluded: .env (regenerable from the SOPS-encrypted repo copy —
# and its absence means backups carry zero secrets), Caddyfile/compose (in the
# repo), Caddy's TLS state (re-minted for free on a rebuilt box).
#
# On success this pings the healthchecks.io dead-man's switch. The alert fires
# on SILENCE, so every failure mode — this script erroring, the timer never
# firing, the box being down — surfaces through one signal, with no
# failure-path code here. BACKUP_PING_URL arrives via the service unit from
# /srv/steamlens/.env (SOPS-managed like every box secret); when unset, the
# ping is skipped and the silence itself raises the alert.
set -euo pipefail

PROJECT=steamlens
DB=/srv/${PROJECT}/data/serve.db
REMOTE=gdrive:${PROJECT}-backups # rclone remote, scope drive.file (README: Backups)
STAMP=$(date +%F)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

sqlite3 "$DB" ".backup '${WORK}/snapshot.db'"

CHECK=$(sqlite3 "${WORK}/snapshot.db" "PRAGMA integrity_check;")
if [ "$CHECK" != "ok" ]; then
    echo "integrity_check failed on the snapshot: ${CHECK}" >&2
    exit 1
fi

gzip -9 "${WORK}/snapshot.db"

# Idempotent, and keeps the prunes below from erroring on a directory that
# doesn't exist yet (weekly/ is only born on the first Sunday run).
rclone mkdir "${REMOTE}/daily"
rclone mkdir "${REMOTE}/weekly"

rclone copyto "${WORK}/snapshot.db.gz" "${REMOTE}/daily/serve-${STAMP}.db.gz"
if [ "$(date +%u)" = 7 ]; then
    rclone copyto "${WORK}/snapshot.db.gz" "${REMOTE}/weekly/serve-${STAMP}.db.gz"
fi

# Age-based pruning IS the retention scheme: 7 days of dailies, 28 days
# (4 slots) of Sunday weeklies.
rclone delete --min-age 7d "${REMOTE}/daily"
rclone delete --min-age 28d "${REMOTE}/weekly"

if [ -n "${BACKUP_PING_URL:-}" ]; then
    curl -fsS -m 10 --retry 3 -o /dev/null "$BACKUP_PING_URL"
fi

echo "backup ok: serve-${STAMP}.db.gz ($(stat -c%s "${WORK}/snapshot.db.gz") bytes)"
