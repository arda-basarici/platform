# Rebuilding the box, and restoring SteamLens onto it

Written during the first rebuild-and-restore drill (2026-08-30): a blank host and a
blank control node taken to SteamLens serving its real review data in about an hour,
from nothing but the public repositories, the password vault, and the Google account.
The drill ran against a throwaway EC2 host (`runbooks/ansible-test-host.md` owns that
scaffolding); a real disaster differs only at the edges — the differences are listed
at the end.

Measured on the first, unrehearsed run — every fumble included:

| Phase | Stamps | Duration |
|---|---|---|
| Control node from nothing (distro, ansible, keys, certs, clone) | 22:14:04 → ~22:19 | ~5 min |
| Blank Debian 13 host → play → `changed=0` → `verify.sh` 26/26 | 22:22:22 → 22:24:49 | ~2.5 min (the build itself: 88 s) |
| SOPS capability from the vault, tenant deployed, `/healthz` green | 22:36 → 22:44:41 | ~9 min |
| Fresh Drive OAuth, backup pulled, integrity, swap-in, counts verified | → 23:20:45 | ~36 min (three OAuth attempts; a clean pass is minutes) |
| **Total, blank → serving restored data** | 22:14:04 → 23:20:45 | **1 h 06 m 41 s** |

A rerun that follows this runbook instead of discovering it should come in well under
an hour — an estimate, not a measurement, until a second drill stamps it.

## What a rebuild needs, and what it deliberately does not

Needed: the public GitHub repositories (`platform`, `steam-lens`), the Bitwarden
vault (the age workstation-identity note), the Google account behind Drive, and a
host to build on. Not needed, and not used in the drill: anything from the old box,
anything from the old workstation. That absence is the claim being proven.

One rule throughout: **a drill host never receives production liveness URLs**
(`BACKUP_PING_URL`, `RESTORE_PING_URL` stay off it). The play arms the backup timers,
but without the env file they fail without pinging — a drill must not be able to
satisfy production's dead-man for it. For a *real* rebuild the URLs are pushed as the
steamlens README's step 4, and the dead-man goes quiet on its own with the first
nightly pass.

## 1. The control node

The proven pair is **Ubuntu 26.04 with ansible core 2.20 from apt** (this drill and
the original blank-host acceptance both). On Windows that is one command per phase:

```powershell
wsl --install -d Ubuntu-26.04     # prompts for a username; the drill used arda
```

Inside the new distro:

```sh
sudo apt-get update -qq && sudo apt-get install -y ansible git openssl curl age
ansible-playbook --version | head -1          # expect core 2.20.x
ssh-keygen -t ed25519 -N "" -f ~/.ssh/ansible-throwaway -C ansible-throwaway
git clone --depth 1 https://github.com/arda-basarici/platform.git ~/platform
git clone --depth 1 https://github.com/arda-basarici/steam-lens.git ~/steam-lens
```

Clone into the distro's home, not `/mnt/c`: a native-filesystem checkout sidesteps the
world-writable `ANSIBLE_CONFIG` refusal entirely (the `/mnt/c` workaround in
`runbooks/ansible-test-host.md` remains for the laptop's daily control node).

The proxy role wants the origin pair at `~/.platform/certs/`. For a test host,
self-signed under the real names (the `-k` in every check below is what tolerates it);
for a real rebuild, re-issue the Cloudflare Origin CA pair in the dashboard and put it
at the same path for the run only:

```sh
mkdir -p ~/.platform/certs && chmod 0700 ~/.platform/certs
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
  -subj '/CN=*.ardabasarici.dev' -addext 'subjectAltName=DNS:*.ardabasarici.dev,DNS:ardabasarici.dev' \
  -keyout ~/.platform/certs/ardabasarici.dev.key -out ~/.platform/certs/ardabasarici.dev.pem
chmod 0600 ~/.platform/certs/ardabasarici.dev.key
```

sops is not in Ubuntu's apt; it comes from the release page, and the age identity
comes back from the vault:

```sh
curl -sLO https://github.com/getsops/sops/releases/download/v3.13.3/sops_3.13.3_amd64.deb
sudo dpkg -i sops_3.13.3_amd64.deb && rm sops_3.13.3_amd64.deb
mkdir -p ~/.config/sops/age && chmod 0700 ~/.config/sops/age
cat > ~/.config/sops/age/keys.txt      # paste the Bitwarden note, Enter, Ctrl-D
chmod 0600 ~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt
sops -d ~/steam-lens/deploy/box/secrets.enc.env > /dev/null && echo OK
```

Paste the note with Bitwarden's copy button, never a hand selection — the drill's
first attempt silently lost the leading 15 characters of the key. `age-keygen -y`
is the check that costs nothing: it must print the workstation recipient recorded in
`.sops.yaml` (`age15zv…vufr`). The `OK` proves the vault note is a working recovery
path, which is worth knowing *before* a disaster.

## 2. The host, built by the play

Launch (drill: `runbooks/ansible-test-host.md`, with a **Debian 13** image so the
proof host shares the box's major — this drill used `debian-13-amd64-20260826-2582`;
real rebuild: a netcup VPS per `box/README.md`, same play). Inventory per
`ansible/inventory/example.yml` (`backups_require_remote: false` for a drill host),
then:

```sh
cd ~/platform/ansible
ansible -i inventory/local.yml all -m ping                     # pong
ansible-playbook -i inventory/local.yml site.yml               # the build (88 s in the drill)
ansible-playbook -i inventory/local.yml site.yml               # must say changed=0
ansible -i inventory/local.yml all -b -m script -a verify.sh   # ALL PASS (502s: no app yet)
curl -sk --connect-timeout 6 https://<host-ip>/ ; echo $?      # 28 - only Cloudflare may speak
```

## 3. The SteamLens tenant

The image pulls anonymously from GHCR; compose comes from the app repository; the
`.env` is decrypted here and piped over ssh, never landing in a checkout:

```sh
SSH="ssh -i $HOME/.ssh/ansible-throwaway admin@<host-ip>"      # real box: ssh box, user arda
$SSH 'sudo install -d -m 0755 -o admin -g admin /srv/steamlens /srv/steamlens/data'
scp -i ~/.ssh/ansible-throwaway ~/steam-lens/compose.yaml admin@<host-ip>:/srv/steamlens/compose.yaml
sops -d ~/steam-lens/deploy/box/secrets.enc.env | $SSH "umask 077 && tr -d '\r' > /srv/steamlens/.env"
$SSH 'cd /srv/steamlens && docker compose pull -q && docker compose up -d'
$SSH 'curl -sk --resolve steamlens.ardabasarici.dev:443:127.0.0.1 https://steamlens.ardabasarici.dev/healthz'
```

Fifteen seconds from `pull` to a green `/healthz` in the drill — through Caddy, with
the app's real hostname, on an empty store. The check runs *on* the host because the
origin firewall drops non-Cloudflare 443 by design; the full visitor path through
Cloudflare is untestable on a host no DNS points at, and this runbook does not claim
it. On a real rebuild the DNS already points here (or moves here), and the external
monitors become that check.

## 4. Drive access, from nothing

The finding this drill exists for: **a fresh `drive.file` authorization with rclone's
shared client id sees the backups** — Drive scopes access by OAuth *application*, the
shared client is the application, and the box's dead credential is not needed. The
2026-08-30 drill listed exactly the 7 dailies + 4 Sunday weeklies and restored from
one. Two caveats keep this honest: it holds only while rclone's shared client id
lives (its retirement is announced for during 2026 — the platform FIXLOG carries the
follow-up ruling), and the fallback needs no rclone at all: download the object in
the Drive web UI and `scp` it to the host.

The OAuth dance that actually works headless — authorize *locally on the control
node*, then ship the whole config (the interactive `config_token>` paste over ssh
mangles wrapped clipboard lines and burned two attempts; do not use it):

```sh
rclone config create gdrive drive scope drive.file     # prints a URL; sign in, approve
rclone lsf gdrive:steamlens-backups/daily/             # the 7 dailies, or stop here
scp -i ~/.ssh/ansible-throwaway ~/.config/rclone/rclone.conf admin@<host-ip>:/home/admin/.config/rclone/rclone.conf
$SSH 'chmod 600 ~/.config/rclone/rclone.conf && rclone lsf gdrive:steamlens-backups/daily/ | head -3'
```

This transported token is freshly minted from the recoverable Google account — the
forbidden shortcut was only ever copying the *old box's* credential, which proves
nothing about surviving its loss.

## 5. Restore and swap-in

The steamlens README's disaster procedure, exercised end to end for the first time in
this drill:

```sh
$SSH 'rclone copyto gdrive:steamlens-backups/daily/serve-<date>.db.gz /tmp/restore.db.gz \
  && gunzip /tmp/restore.db.gz && sqlite3 /tmp/restore.db "PRAGMA integrity_check;"'
$SSH 'cd /srv/steamlens && docker compose down \
  && rm -f data/serve.db-wal data/serve.db-shm \
  && mv /tmp/restore.db data/serve.db && docker compose up -d'
$SSH 'curl -sk --resolve steamlens.ardabasarici.dev:443:127.0.0.1 https://steamlens.ardabasarici.dev/healthz; echo; \
  sqlite3 "file:/srv/steamlens/data/serve.db?mode=ro" \
  "SELECT (SELECT count(*) FROM classify_cache), (SELECT count(*) FROM reviews), (SELECT count(*) FROM mentions), (SELECT count(*) FROM reports);"'
```

The pass is the counts matching the backup object's recorded evidence — the drill's
`2196|21135|29878|43` matched the same object's hand check and its monthly-timer run
digit for digit, on a different host, through a different credential. The recovery
point stays the nightly cadence: up to one day of writes.

## 6. Drill teardown

Terminate the instance, delete the security group and key pair with it
(`ansible-test-host.md`), and `wsl --unregister Ubuntu-26.04` — which destroys the
distro's age-key copy, ssh keys, and the rclone token's only storage. Do **not**
revoke the rclone grant in the Google account's permissions page: the live box's
backup token rides the same application grant, and revoking it kills the nightly
backup. Post-drill rotation of the two app secrets is not routine — only on a
concrete reason to distrust the drill host.

## What a real disaster adds that the drill cannot

- The host is a netcup VPS (`box/README.md`), not EC2; the ssh user is `arda`.
- The Cloudflare Origin CA pair is re-issued in the dashboard, not self-signed.
- DNS: the proxied records move to the new origin IP (`terraform/stacks/edge`,
  `records.tf` — one apply).
- The liveness URLs are pushed (steamlens README step 4) and both healthchecks
  checks go green on their own schedule.
- The CD path is re-armed: `deploy.sh` installed, the forced-command key re-minted,
  the GitHub `production` environment secrets refreshed
  (`steam-lens/deploy/box/README.md`, one-time CD setup).
- Frappe/hr is rebuilt from its own repository's path; its MariaDB has no backup by
  ruling (regenerable synthetic data), so this runbook's restore claim is
  SteamLens-shaped only.
