# steamlens — platform adapter

The platform's side of steam-lens: its site stanza on the box proxy and the
nightly backup of its store. This directory is allowed to know the
application (one SQLite file is its whole durable state); the application
repository (`arda-basarici/steam-lens`) owns the image, the Compose stack
under `/srv/steamlens/`, `deploy.sh`, and the application's own secrets.

## Contract

| Value | Producer | Where it is used |
|---|---|---|
| `steamlens.ardabasarici.dev` | platform: Cloudflare A record (proxied) + `sites.caddy` | the application's README and links |
| upstream `steamlens-app-1:8000` | application: its Compose service name on `web` | `sites.caddy` → `reverse_proxy` |
| the `web` network | platform | the application's Compose file joins it as external |
| request-body cap 16KB, the security-header set, immutable caching for `/static/*` | platform, in `sites.caddy`; each explained in place | the application relies on the cap sitting in front of it |
| `X-Forwarded-For` = the one verified visitor IP (replaced, not appended) | platform | the application's rate-limit gate reads the last entry |
| durable state: `/srv/steamlens/data/serve.db` (SQLite, WAL) | application | `backup.sh` |
| `BACKUP_PING_URL` | platform (this directory's SOPS file) | `steamlens-backup.service` |

A rename on either side is a contract change and edits both READMEs.

## Files

| File | Installed as | Role |
|---|---|---|
| `sites.caddy` | imported by the box Caddyfile from the mounted checkout | the site stanza |
| `backup.sh` | runs from the checkout, `/srv/platform/projects/steamlens/backup.sh` | snapshot, verify, ship, prune, ping |
| `steamlens-backup.service` | `/etc/systemd/system/steamlens-backup.service` | the oneshot the timer fires |
| `steamlens-backup.timer` | `/etc/systemd/system/steamlens-backup.timer` | 03:30 box-local, `Persistent=true` |
| `backup.enc.env` | decrypted to `/etc/platform/steamlens/backup.env` (0600) | `BACKUP_PING_URL` |

The unit files carry the tenant's name because unit names are host-global;
two tenants' `backup.timer` would collide in `/etc/systemd/system/`.

## Backups (nightly, to Google Drive)

`backup.sh` snapshots the store with `sqlite3 .backup` (WAL-aware, safe
against concurrent writers, never a raw copy of a live database),
integrity-checks the snapshot before shipping (an unverified upload of a
corrupt file preserves the corruption, not the data), gzips, uploads to Drive
with the box's rclone, and prunes to 7 dailies + 4 Sunday weeklies. On success
it pings a healthchecks.io check, so the alert channel is *silence*: script
failure, dead timer, and dead box all raise the same email. Secrets are
deliberately not backed up: the application's `.env` regenerates from its
SOPS file, so a compromised Drive account holds review data, never keys. The
review data itself is what the backup exists for and is treated as sensitive.

### One-time setup

```sh
# 1. On the box: the two tools the script calls.
sudo apt-get install -y sqlite3 rclone

# 2. On the box, as the login user: the Drive remote. Name it `gdrive`
#    (backup.sh addresses it by that name), storage type `drive`, scope
#    `drive.file` — the token can then only touch files rclone itself
#    created; a compromised box can burn the backups, never read the Drive.
#    Skip client_id/secret (rclone's built-in is fine at this volume, and a
#    self-made "testing"-mode OAuth app expires its token every 7 days).
#    The box is headless: answer "n" to auto config, run the printed
#    `rclone authorize "drive" ...` line on the workstation, paste the token.
rclone config

# 3. Create a check at healthchecks.io (period 1 day, grace ~2 h). Its ping
#    URL is the one value in backup.enc.env (SECRETS.md: platform-owned,
#    encrypted to the workstation + recovery recipients, no key on the box):
sops projects/steamlens/backup.enc.env      # → BACKUP_PING_URL=https://hc-ping.com/<uuid>

# 4. Once, in an interactive session on the box: the runtime directory,
#    owned by the login user so later pushes need no sudo (sudo has no tty
#    on a piped ssh).
sudo install -d -m 0750 -o arda -g arda /etc/platform/steamlens

#    Then, from the workstation, every time the value changes: decrypt here,
#    pipe over ssh, land it 0600. The checkout never holds plaintext.
sops -d projects/steamlens/backup.enc.env | \
  ssh box 'umask 077 && cat > /etc/platform/steamlens/backup.env'

# 5. Install the units from the checkout, enable the timer.
ssh box 'chmod +x /srv/platform/projects/steamlens/backup.sh \
  && sudo cp /srv/platform/projects/steamlens/steamlens-backup.{service,timer} /etc/systemd/system/ \
  && sudo systemctl daemon-reload && sudo systemctl enable --now steamlens-backup.timer'

# 6. First run, by hand, watching the journal:
ssh box 'sudo systemctl start steamlens-backup.service \
  && journalctl -u steamlens-backup.service -n 20 --no-pager'
```

The service runs as the login user, which owns `data/`, the rclone remote,
and the env file; nothing on the box other than that user and root reads it.

Setup is not done until a restore has been verified: a backup never restored
is a hope. Pull the fresh backup back and compare it against the live db:

```sh
ssh box
rclone copyto "gdrive:steamlens-backups/daily/serve-$(date +%F).db.gz" /tmp/restore.db.gz
gunzip /tmp/restore.db.gz
sqlite3 /tmp/restore.db "PRAGMA integrity_check;"          # → ok
sqlite3 /tmp/restore.db "SELECT count(*) FROM classify_cache;"
sqlite3 "file:/srv/steamlens/data/serve.db?mode=ro" \
  "SELECT count(*) FROM classify_cache;"                   # → same count (± writes since 03:30)
rm /tmp/restore.db
```

Run on 2026-08-30 against that morning's object: `integrity_check` ok, 30.7 MB,
and every count in the live store one day of writes above the backup's
(`classify_cache` 2 196 → 2 252, `reviews` 21 135 → 21 684, `mentions` 29 878 →
30 453, `reports` 43 → 44); Drive held exactly 7 dailies and 4 Sunday weeklies.
The nightly cadence is also the recovery point: a real restore loses up to one
day, which the box's rate of writes (≈550 reviews/day that week) puts a number
on. Counting more than one table matters: a cache that fills and a ledger that
grows drift differently, so a match on one column proves less than it looks.

### Restoring for real (disaster runbook)

```sh
cd /srv/steamlens && docker compose down
rclone lsl gdrive:steamlens-backups/daily                  # pick the newest good one
rclone copyto gdrive:steamlens-backups/daily/serve-<date>.db.gz /tmp/restore.db.gz
gunzip /tmp/restore.db.gz && sqlite3 /tmp/restore.db "PRAGMA integrity_check;"
mv data/serve.db data/serve.db.broken                      # keep the evidence
rm -f data/serve.db-wal data/serve.db-shm                  # stale WAL sidecars poison a restored db
mv /tmp/restore.db data/serve.db
# Port 80 is retired and 443 speaks TLS for the domain, so the local check
# rides SNI via --resolve; -k because the Origin CA cert is trusted only by
# Cloudflare's edge, not by curl.
docker compose up -d && curl -sk --resolve steamlens.ardabasarici.dev:443:127.0.0.1 \
  https://steamlens.ardabasarici.dev/healthz
```
