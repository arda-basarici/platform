#!/usr/bin/env bash
# Nightly backup of the leave-impact application's PostgreSQL — capture, dump,
# preflight, ship by conditional create, ping.
#
# The application's durable state is one PostgreSQL database (the run log and
# its ledgers, the publishable attempts, the corpus cache). The dump is
# pg_dump's custom format (its own compression, no outer gzip) taken inside a
# REPEATABLE READ transaction the script holds open: the transaction exports its
# snapshot, reads the application's `ledger_capture` view (one row per ledger:
# the figures the restore check compares), and pg_dump runs on that same
# snapshot, so the capture and the dump describe one instant by construction —
# a capture taken beside the dump could differ by an admission that landed in
# between, and a monthly check that fails on that is a false alert. Both run in
# a throwaway container from the service's own image on the stack's private
# network (found by Compose labels, never by a container name), so pg_dump and
# the server are one version even when the pin moves.
#
# Before shipping, `pg_restore --list` reads the archive back: a truncated or
# corrupt archive fails here, not at the recovery. The object is written once
# with `If-None-Match: *` (the bucket refuses a plain put and a second put of
# the key with 412), carries S3's own SHA-256 (verified by S3 on upload) and the
# same digest with the capture as user metadata, where the restore check reads
# them from the object it restores. The instance may put and get here and
# nothing else; pruning is the bucket's lifecycle (seven dailies, four weeklies).
#
# Excluded by construction: secrets (Parameter Store), the image (the registry),
# the worlds and the run exports (the buckets); nothing inside the database is
# excluded, the corpus cache included (regenerable, but a restore that needs no
# re-fetch is a restore that works offline). The success ping goes to the
# healthchecks.io dead-man only at the end, so every failure mode is one
# signal: silence. The ping URL is read from Parameter Store at run time (the
# host's secrets idiom; nothing on disk); while it still holds the stack's
# UNSET placeholder the ping is skipped and said so.
#
# Runs as root from the systemd unit beside it: the host has no login user, the
# deploy itself runs as root over SSM, and the Docker socket is root's.
# BACKUP_BUCKET arrives from the unit's environment file, which cloud-init
# renders from the stack's output.
set -euo pipefail

: "${BACKUP_BUCKET:?the backup bucket name: the unit environment file, rendered by cloud-init}"
REGION=eu-central-1
PROJECT=leaveimpact # the application's Compose project; the service, user, database and password name are the contract row's
STATE_DIR=/srv/backups
STAMP=$(date -u +%F)
KEY="daily/${PROJECT}-${STAMP}.dump"

WORK=$(mktemp -d -p "$STATE_DIR")
trap 'rm -rf "$WORK"' EXIT

# The running service by its Compose labels: its image is the version to dump
# with, its private network the way to reach it.
CONTAINER=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=postgres")
NETWORK=$(docker network ls -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.network=store")
# Exactly one of each, or the labels name the wrong thing (a workstation that
# also runs the development stack matches twice; the host runs one project).
case "$CONTAINER" in
    "") echo "no running postgres service in Compose project $PROJECT" >&2; exit 1 ;;
    *$'
'*) echo "more than one postgres container carries Compose project $PROJECT" >&2; exit 1 ;;
esac
case "$NETWORK" in
    "" | *$'
'*) echo "the store network of Compose project $PROJECT is missing or ambiguous" >&2; exit 1 ;;
esac
IMAGE=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER")

PGPASSWORD=$(aws ssm get-parameter --region "$REGION" --with-decryption --name /leave-agent/postgres-password --query Parameter.Value --output text)
export PGPASSWORD

# One psql session holds the transaction; `\!` runs pg_dump in the same
# container while it is open. `\!` interpolates no psql variable, so the
# snapshot id crosses as an environment variable set by `\setenv`. A failed
# pg_dump removes its own output, and the empty-archive check below catches it.
docker run --rm -i --network "$NETWORK" -v "$WORK:/work" \
    -e PGPASSWORD -e PGHOST=postgres -e PGUSER="$PROJECT" -e PGDATABASE="$PROJECT" \
    "$IMAGE" psql -X -q -At -v ON_ERROR_STOP=1 <<'SQL'
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT pg_export_snapshot() AS snapshot \gset
\setenv PGSNAPSHOT :snapshot
\o /work/capture.json
SELECT coalesce(jsonb_agg(c ORDER BY c.ledger_id), '[]'::jsonb) FROM ledger_capture c;
\o
\! pg_dump --format=custom --snapshot="$PGSNAPSHOT" --file=/work/dump "$PGDATABASE" || rm -f /work/dump
COMMIT;
SQL

DUMP="$WORK/dump"
if [ ! -s "$DUMP" ]; then
    echo "pg_dump produced no archive" >&2
    exit 1
fi
CAPTURE=$(cat "$WORK/capture.json")

# The preflight: the archive's table of contents, and it must name table data.
TABLES=$(docker run --rm -v "$WORK:/work" "$IMAGE" pg_restore --list /work/dump | grep -c 'TABLE DATA' || true)
if [ "$TABLES" -eq 0 ]; then
    echo "pg_restore --list found no table data in the archive" >&2
    exit 1
fi

SHA=$(sha256sum "$DUMP" | cut -d' ' -f1)
SHA_B64=$(openssl dgst -sha256 -binary "$DUMP" | base64 -w0)

# User metadata is bounded at 2 KB for the object; the capture is one short
# row per ledger. If the instance ever outgrows it, the fallback is a sidecar
# object under the same conditional put — not built ahead of the need.
# The capture as a JSON string value: backslashes first, then quotes.
ESCAPED=${CAPTURE//\\/\\\\}
ESCAPED=${ESCAPED//\"/\\\"}
META="{\"sha256\":\"$SHA\",\"capture\":\"$ESCAPED\"}"
if [ "${#META}" -gt 1900 ]; then
    echo "capture metadata is ${#META} bytes, over the budget; the sidecar fallback is due" >&2
    exit 1
fi

put() {
    aws s3api put-object --region "$REGION" --bucket "$BACKUP_BUCKET" --key "$1" \
        --body "$DUMP" --if-none-match '*' \
        --checksum-algorithm SHA256 --checksum-sha256 "$SHA_B64" \
        --content-type application/octet-stream --metadata "$META" \
        --query VersionId --output text
}

VERSION=$(put "$KEY")
# Sundays also keep a weekly copy (its own key, its own 28-day retention).
if [ "$(date -u +%u)" = 7 ]; then
    put "weekly/${PROJECT}-${STAMP}.dump" >/dev/null
fi

# The key the restore check prefers over the date it would compute, so a
# backup that ran late still names its own object. Written whole, then moved.
printf '%s\n' "$KEY" > "$WORK/last-object"
mv "$WORK/last-object" "$STATE_DIR/last-object"

PING_URL=$(aws ssm get-parameter --region "$REGION" --with-decryption --name /leave-agent/backup-ping-url --query Parameter.Value --output text)
case "$PING_URL" in
    UNSET*) echo "no ping URL put yet (/leave-agent/backup-ping-url holds the placeholder); the dead-man is not armed" ;;
    *) curl -fsS -m 10 --retry 3 -o /dev/null "$PING_URL" ;;
esac

echo "backup ok: $KEY version $VERSION ($(stat -c%s "$DUMP") bytes, sha256 $SHA, $TABLES tables)"
