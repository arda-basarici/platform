#!/usr/bin/env bash
# Monthly restore check of the steamlens backup — pull, verify, compare, ping.
#
# The nightly backup's ping proves the script ran, not that its output
# restores. This one restores the newest daily object on the same host and
# compares it with the live store, the way the first hand-run check did
# (README, "Backups"): integrity_check on the restored file, then a row count
# on four tables in both. A backup is accepted when every live count is at
# least the backup's — a table that only ever grows can only be ahead in the
# live db — and the object is at most two days old (a stale "newest" means the
# nightly stopped and the dead-man is the alert that already fired).
#
# Read-only against the live store (mode=ro), one temp dir freed on exit. The
# same silence-shaped channel as the backup: RESTORE_PING_URL is pinged only
# on a pass, so a diverged or stale backup surfaces as a missed monthly ping.
# Deliberately NOT a swap-in: the disaster procedure stays a human's run.
set -euo pipefail

PROJECT=steamlens
LIVE=/srv/${PROJECT}/data/serve.db
REMOTE=gdrive:${PROJECT}-backups/daily
MAX_AGE_DAYS=2
COUNTS="SELECT (SELECT count(*) FROM classify_cache) || '|' || (SELECT count(*) FROM reviews)
     || '|' || (SELECT count(*) FROM mentions) || '|' || (SELECT count(*) FROM reports);"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Objects are named serve-YYYY-MM-DD.db.gz, so the lexically last is the newest.
NEWEST=$(rclone lsf "$REMOTE" | sort | tail -n 1)
if [ -z "$NEWEST" ]; then
    echo "no objects under ${REMOTE}" >&2
    exit 1
fi
STAMP=${NEWEST#serve-}; STAMP=${STAMP%.db.gz}
AGE_DAYS=$(( ( $(date +%s) - $(date -d "$STAMP" +%s) ) / 86400 ))
if [ "$AGE_DAYS" -gt "$MAX_AGE_DAYS" ]; then
    echo "newest backup ${NEWEST} is ${AGE_DAYS} days old (max ${MAX_AGE_DAYS})" >&2
    exit 1
fi

rclone copyto "${REMOTE}/${NEWEST}" "${WORK}/restore.db.gz"
gunzip "${WORK}/restore.db.gz"

CHECK=$(sqlite3 "${WORK}/restore.db" "PRAGMA integrity_check;")
if [ "$CHECK" != "ok" ]; then
    echo "integrity_check failed on ${NEWEST}: ${CHECK}" >&2
    exit 1
fi

BACKUP_COUNTS=$(sqlite3 "${WORK}/restore.db" "$COUNTS")
LIVE_COUNTS=$(sqlite3 "file:${LIVE}?mode=ro" "$COUNTS")
IFS='|' read -r -a b <<< "$BACKUP_COUNTS"
IFS='|' read -r -a l <<< "$LIVE_COUNTS"
for i in "${!b[@]}"; do
    if [ "${l[$i]}" -lt "${b[$i]}" ]; then
        echo "live store behind the backup (classify_cache|reviews|mentions|reports): live ${LIVE_COUNTS}, backup ${BACKUP_COUNTS}" >&2
        exit 1
    fi
done

if [ -n "${RESTORE_PING_URL:-}" ]; then
    curl -fsS -m 10 --retry 3 -o /dev/null "$RESTORE_PING_URL"
fi

echo "restore check ok: ${NEWEST} (${AGE_DAYS}d old, restored db $(stat -c%s "${WORK}/restore.db") bytes uncompressed) integrity ok;" \
     "classify_cache|reviews|mentions|reports backup ${BACKUP_COUNTS} live ${LIVE_COUNTS}"
