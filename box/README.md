# The box — provisioning, hardening, the proxy

One small VPS (netcup, Debian) runs every project as a self-contained Docker
Compose stack behind a single box-owned Caddy (this directory), all joined by
one shared Docker network. A project lands as its own Compose stack plus one
directory of site stanzas under `projects/<name>/` (`runbooks/add-a-tenant.md`).
Nothing here is box-specific: a rebuilt box replays this file, and
`ansible/site.yml` is its transcription (one role per section below, proven
on a blank Debian 12 host: `runbooks/ansible-test-host.md`). This file stays
the readable runbook and the explanation of every choice; the roles are the
executable form of the same steps.

## Layout on the box

```
/srv/platform/            ← this repository, checked out: deployment material
    box/                     the proxy stack (compose.yaml, Caddyfile, firewall)
    projects/<name>/         tenant stanzas, backup units and scripts
/etc/platform/            ← machine-local runtime material, never in git
    box/certs/               the Cloudflare Origin CA pair
    <name>/                  decrypted per-tenant files (steamlens/backup.env)
/srv/<project>/           ← one directory per application: its compose.yaml,
                             .env, data/ — owned by the application repository
```

Commands below that use `sudo` are run in an interactive session on the box
(`ssh -t box '…'` or a plain login): sudo asks for a password, and a piped,
non-interactive ssh has no tty to ask on.

Two rules keep the checkout honest:

- **It is deployment material, never a working copy.** No edits on the box;
  a change is a commit here, then a pull. The deploy is fast-forward-only
  (`git pull --ff-only`), so a checkout that somehow diverged fails the
  deploy instead of merging box-local state.
- **Cloning creates no runtime state.** `/etc/platform/` is provisioned by
  hand (below) and the repository only documents what it expects to find there.

`git -C /srv/platform rev-parse HEAD` answers "which platform configuration is
deployed". It says nothing about which application image each tenant runs;
those are the applications' own deploys.

`/srv/<project>/data/` is the bind-mounted application state. It outlives
every image and container, and a tenant's backup reads it from the host
without entering Docker. Owned by uid 1000 (the login user; images run as the
same uid by convention).

## One-time host provisioning

```sh
# Docker Engine + compose plugin, per docs.docker.com/engine/install/debian
# (apt repo, not the distro package — the distro's lags majors behind).
sudo apt-get update && sudo apt-get install -y ca-certificates curl git
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# Run docker as the login user (re-log to take effect).
sudo usermod -aG docker $USER

# The one shared proxy network every project stack joins.
docker network create web

# The platform checkout (public repository, no credential) and the runtime root.
sudo git clone https://github.com/arda-basarici/platform /srv/platform
sudo chown -R $USER:$USER /srv/platform
# Traversable by everyone; each child directory carries its own protection
# (box/ root-only, <tenant>/ owned by the login user).
sudo install -d -m 0755 -o root -g root /etc/platform
```

## Hardening — verify, then fix only what fails

A fresh provider image may already ship most of this (the 2026-08-08 box did:
ssh key-only, ufw active, unattended-upgrades wired). Verify the actual state
first; change only what a check refutes.

```sh
# ssh: key-only, no root login. sshd -T prints the *effective* config with
# /etc/ssh/sshd_config.d/ drop-ins resolved — grepping sshd_config alone can lie.
sudo sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin|kbdinteractiveauthentication)'
# Want all three "no". If not, fix via a drop-in (never edit sshd_config itself),
# and keep the current session open while testing a fresh login:
#   printf 'PasswordAuthentication no\nPermitRootLogin no\nKbdInteractiveAuthentication no\n' \
#     | sudo tee /etc/ssh/sshd_config.d/50-hardening.conf && sudo systemctl reload ssh

# Firewall: default deny incoming; ssh is the ONLY host-level allowance.
# Allow 22 BEFORE enable, while the session that would be locked out is
# still open. 80/443 are deliberately not allowed: the web ports' guard is
# the DOCKER-USER layer below — and the absence of a ufw allowance is
# itself load-bearing (it is what closes the docker-proxy path; see below).
sudo ufw allow 22/tcp comment 'ssh'
sudo ufw enable

# Security patches auto-install; the timers must show a next-fire time.
sudo apt-get install -y unattended-upgrades
systemctl list-timers 'apt-daily*' --all
```

## Origin firewall — only Cloudflare reaches the published ports

The trap that shapes this design: **Docker-published ports bypass ufw**.
Inbound IPv4 to a published port is DNAT'ed and *forwarded* into the
container, consulting the FORWARD chain (where Docker gives user rules first
say via the `DOCKER-USER` hook) and never ufw's INPUT rules. So the web ports
are guarded in two layers, one per path the traffic actually takes:

- **IPv4 (forwarded): `firewall.sh`** owns the DOCKER-USER chain — 443
  admitted from Cloudflare's published ranges only (the same list the
  Caddyfile's `trusted_proxies` pins; refresh both together), everything else
  the internet sends at a container dropped. `box-firewall.service` re-applies
  it each boot, ordered `Before=docker.service` so no gap opens.
- **IPv6 (docker-proxy): ufw's default deny.** The containers have no v6
  address, so the `[::]:443` publish is served by docker-proxy, a *host
  process*, which answers to INPUT and therefore to ufw. With no 80/443 allow
  rules, default-deny closes that door. No allowance is missing: Cloudflare
  dials the origin v4-only (the origin DNS record is an A record) and
  exclusively over 443 (SSL Full (strict)).

Lockout safety, why this is safe to apply over ssh: DOCKER-USER sees only
traffic forwarded into containers; the ssh session rides INPUT, which the
script never touches. A botched rule set can dark the sites, never the shell.

```sh
# Install the unit (the script runs from the checkout), apply now
# (idempotent — safe to re-run):
ssh -t box 'chmod +x /srv/platform/box/firewall.sh \
  && sudo cp /srv/platform/box/box-firewall.service /etc/systemd/system/ \
  && sudo systemctl daemon-reload && sudo systemctl enable --now box-firewall.service'

# Verify: domains green, bare origin IP (never written here — the repository
# is public and the proxy hides it; the `box` ssh alias resolves it) dead on
# both ports.
curl -s https://steamlens.ardabasarici.dev/healthz          # → {"status":"ok",...}
curl -s --connect-timeout 5 http://<origin-ip>/healthz      # → timeout
curl -sk --connect-timeout 5 https://<origin-ip>/           # → timeout
```

The Compose convention still stands as the inner wall: only the box proxy
ever publishes a port. Check the live surface with
`docker ps --format 'table {{.Names}}\t{{.Ports}}'`: only the Caddy container
may show port arrows.

## Domain + TLS (Cloudflare, orange-cloud)

Every hostname fronts the box through Cloudflare's proxy. The DNS A records
are **proxied and must stay proxied**: a grey-cloud save, even briefly, puts
the origin IP into passive-DNS archives permanently, and the origin-hiding
half of the proxy dies retroactively.

The visitor→Cloudflare leg rides Cloudflare's edge certificate; the
Cloudflare→origin leg runs SSL mode **Full (strict)** against a Cloudflare
Origin CA pair (dashboard → SSL/TLS → Origin Server; covers the apex +
`*.ardabasarici.dev`, 15-year validity). The pair is trusted only by
Cloudflare's edge, exactly its job, and is re-issuable from the dashboard at
any time, so the box-side files are the whole story: never committed,
nothing to back up. It lives at `/etc/platform/box/certs/`, mounted read-only
into Caddy at `/etc/caddy/certs/`, the path the global Caddyfile's `origin_tls`
snippet names; every stanza imports the snippet rather than the path.

```sh
# From the workstation, after issuing the pair in the dashboard. Explicit
# permissions: the key is readable by root only; Caddy runs as root in the
# official image and reads it through the read-only mount.
scp ardabasarici.dev.pem ardabasarici.dev.key box:/tmp/
ssh -t box 'sudo install -d -m 0750 /etc/platform/box/certs \
  && sudo install -m 0644 /tmp/ardabasarici.dev.pem /etc/platform/box/certs/ \
  && sudo install -m 0600 /tmp/ardabasarici.dev.key /etc/platform/box/certs/ \
  && rm /tmp/ardabasarici.dev.pem /tmp/ardabasarici.dev.key'
```

Since 2026-08-28 the records and the zone settings are Terraform's:
`terraform/stacks/edge` describes them exactly (imported from the hand-made
setup on a zero-diff plan), and a change to a record or a setting is a change
there, applied from the laptop; the dashboard is read-only for them. The Origin
CA pair is not: it stays a dashboard-issued, box-side file, exactly as above.

Two Caddyfile pieces make the proxy honest (both explained in place there):
`trusted_proxies` lists Cloudflare's published ranges (cloudflare.com/ips;
refresh the list if Cloudflare ever announces a change) so a forwarded
identity is only believed when the peer really is Cloudflare, and each stanza
*replaces* `X-Forwarded-For` with the one verified visitor IP. There is no
bare-IP `:80` stanza and the proxy publishes 443 only: Cloudflare dials the
origin exclusively over HTTPS in Full (strict), visitor HTTP is redirected at
the edge, and the origin firewall (above) drops direct-to-IP callers before
Caddy ever sees them.

## The proxy: bring-up and every later change

```sh
# Once per box:
cd /srv/platform/box && docker compose up -d

# Every config change (box/Caddyfile or any projects/<name>/sites.caddy)
# afterwards — the whole deploy. `up -d` alone deploys nothing here: a config
# edit changes no compose definition, so Compose sees nothing to do — the
# reload is the deploy. Caddy validates the new configuration before swapping
# it in, so a broken file fails closed with the old config still serving;
# a good one swaps with zero downtime.
cd /srv/platform && git pull --ff-only && cd box \
  && docker compose exec caddy caddy reload --config /etc/caddy/box/Caddyfile

# Only a changed compose.yaml needs the container recreated instead
# (a few seconds of downtime, all sites):
cd /srv/platform && git pull --ff-only && cd box && docker compose up -d

# Then, always: every hostname answers through the visitor path.
curl -s -o /dev/null -w '%{http_code}\n' https://steamlens.ardabasarici.dev/healthz
curl -s -o /dev/null -w '%{http_code}\n' https://hr.ardabasarici.dev/
curl -s -o /dev/null -w '%{http_code}\n' https://hr-w1.ardabasarici.dev/
```

Rollback is the previous commit: `git -C /srv/platform checkout <sha> -- box
projects` and the same reload (or `up -d`, if compose.yaml was what rolled
back). The checkout is then dirty on purpose; restore it with `git checkout .`
once the fix is pushed.

Applications bring themselves up from their own directories, with images from
GHCR; the box never builds. The `box` alias lives in the workstation's
`~/.ssh/config` (it was `steamlens` while steam-lens owned this file).
