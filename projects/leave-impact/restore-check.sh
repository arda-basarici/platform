#!/usr/bin/env bash
# Monthly restore check of the leave-impact backup — fetch, verify, restore,
# ask the application, ping.
#
# The nightly ping proves the backup ran, not that its output restores. This
# fetches last night's object from the bucket (the shipped bytes, not a local
# copy), checks its digest against the metadata the backup wrote, restores it
# into a scratch database on the same PostgreSQL service, and hands the
# object's capture to the application's own verification command, which is the
# verdict: the schemas at the code's version, every ledger's head equal to the
# fold of its entries, the restored `ledger_capture` rows equal to the capture
# row for row, a published replay resolved and rendered. The command imports
# nothing that executes, so a restored open attempt cannot cause a paid call
# (the application's structural rule, not a flag here). The scratch database is
# dropped on every exit.
#
# The object is the one the backup named in its state file, or today's key by
# date when the file is absent; an object older than two days fails the check
# (the nightly stopped, and the backup dead-man is the alert that already
# fired). The success ping goes to its own healthchecks.io dead-man only on a
# pass, read from Parameter Store at run time; while that parameter holds the
# UNSET placeholder the ping is skipped and said so. Runs as root from the unit
# beside it, an hour after the nightly backup on the first of the month.
# Deliberately not a swap-in: a real recovery is the application runbook's.
set -euo pipefail

: "${BACKUP_BUCKET:?the backup bucket name: the unit environment file, rendered by cloud-init}"
REGION=eu-central-1
PROJECT=leaveimpact
APP_DIR=/srv/app
STATE_DIR=/srv/backups
SCRATCH_DB=leaveimpact_restore_check
MAX_AGE_DAYS=2

if [ -s "$STATE_DIR/last-object" ]; then
    KEY=$(cat "$STATE_DIR/last-object")
else
    KEY="daily/${PROJECT}-$(date -u +%F).dump"
fi
# Keys are daily/<project>-YYYY-MM-DD.dump; the date is the object's age.
STAMP=${KEY#daily/"${PROJECT}"-}
STAMP=${STAMP%.dump}
AGE_DAYS=$(( ( $(date -u +%s) - $(date -u -d "$STAMP" +%s) ) / 86400 ))
if [ "$AGE_DAYS" -gt "$MAX_AGE_DAYS" ]; then
    echo "newest backup $KEY is $AGE_DAYS days old (max $MAX_AGE_DAYS)" >&2
    exit 1
fi

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

WORK=$(mktemp -d -p "$STATE_DIR")

# A client in the service's own image, for createdb, pg_restore and dropdb.
pg() {
    docker run --rm -v "$WORK:/work" --network "$NETWORK" \
        -e PGPASSWORD -e PGHOST=postgres -e PGUSER="$PROJECT" -e PGDATABASE="$PROJECT" \
        "$IMAGE" "$@"
}

cleanup() {
    pg dropdb --if-exists "$SCRATCH_DB" || echo "scratch database $SCRATCH_DB not dropped; drop it by hand" >&2
    rm -rf "$WORK"
}
trap cleanup EXIT

aws s3api get-object --region "$REGION" --bucket "$BACKUP_BUCKET" --key "$KEY" "$WORK/dump" >/dev/null
EXPECTED=$(aws s3api head-object --region "$REGION" --bucket "$BACKUP_BUCKET" --key "$KEY" --query Metadata.sha256 --output text)
aws s3api head-object --region "$REGION" --bucket "$BACKUP_BUCKET" --key "$KEY" --query Metadata.capture --output text > "$WORK/capture.json"
ACTUAL=$(sha256sum "$WORK/dump" | cut -d' ' -f1)
if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "digest mismatch on $KEY: object $ACTUAL, metadata $EXPECTED" >&2
    exit 1
fi

pg dropdb --if-exists "$SCRATCH_DB"
pg createdb "$SCRATCH_DB"
pg pg_restore --exit-on-error --dbname "$SCRATCH_DB" /work/dump

# The application's verdict, in its own container from the deployed image, with
# the environment the deploy gives `compose run` (compose.yaml requires the
# password and the data path even for a one-off; the world bucket and region are
# the deploy's literals, read for the rendered replay; every vendor variable
# stays empty). The capture arrives on stdin from the file, never pasted.
cd "$APP_DIR"
APP_TAG=$(cat "$APP_DIR/DEPLOYED")
export APP_TAG
export PGDATA_HOST=/srv/pgdata
export POSTGRES_PASSWORD="$PGPASSWORD"
export LEAVE_IMPACT_WORLD_BUCKET=leave-impact-world-445743457479
export LEAVE_IMPACT_AWS_REGION="$REGION"
docker compose run --rm -T \
    -e DATABASE_URL="postgresql://${PROJECT}:${POSTGRES_PASSWORD}@postgres:5432/${SCRATCH_DB}" \
    app python -m leaveimpact.app verify-restore < "$WORK/capture.json"

PING_URL=$(aws ssm get-parameter --region "$REGION" --with-decryption --name /leave-agent/restore-ping-url --query Parameter.Value --output text)
case "$PING_URL" in
    UNSET*) echo "no ping URL put yet (/leave-agent/restore-ping-url holds the placeholder); the dead-man is not armed" ;;
    *) curl -fsS -m 10 --retry 3 -o /dev/null "$PING_URL" ;;
esac

echo "restore check ok: $KEY (${AGE_DAYS}d old, $(stat -c%s "$WORK/dump") bytes) restored into $SCRATCH_DB and verified by the application"
