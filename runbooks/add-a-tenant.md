# Runbook — add a tenant to the box

Adding a tenant is two changes on purpose (DESIGN, the ownership line): the
application ships itself, the platform wires it. This is the platform half.
Exercised first at the extraction (the tenants it describes already exist);
kept current each time it runs.

## Before starting: what the application must already provide

- Its Compose stack under `/srv/<name>/`, joining the shared network as
  external (`networks: web: external: true`) and publishing no port.
- The container name the proxy will dial (`<service>-1:<port>` on `web`) and,
  if the platform will back it up, the durable-data path and what it holds.
- A hostname under `ardabasarici.dev`.

## Steps

1. **Cloudflare:** an A record for the hostname to the origin, **proxied**
   (orange-cloud; never save it grey, even briefly — the origin IP would enter
   passive-DNS archives permanently). SSL mode is zone-wide (Full (strict))
   and the Origin CA pair already covers `*.ardabasarici.dev`; nothing to issue.
2. **The stanza:** in `projects/<name>/sites.caddy`, one file per tenant
   holding all of its sites (Caddy's import takes a single wildcard, so the
   file name is fixed and the directory is the variable). Copy the shape of
   an existing one: `tls` with the shared pair, `reverse_proxy` to
   the container name with `header_up X-Forwarded-For {client_ip}`. Decide the
   per-tenant policy in the stanza and say why in place: request-body cap,
   security headers (or their absence, when the upstream already sets them),
   caching. Commit.
3. **The README:** `projects/<name>/README.md` with the contract table
   (hostname, upstream, what the stanza enforces, what is backed up). The
   application's README states the same values from its side.
4. **Deploy the proxy:** on the box, `cd /srv/platform && git pull --ff-only
   && cd box && docker compose exec caddy caddy reload --config
   /etc/caddy/box/Caddyfile`. A new stanza is a config change, and the reload
   is the deploy (`up -d` sees no Compose change and does nothing); Caddy
   validates first and swaps in place, the running sites are not interrupted. Then verify
   **every** hostname on the box, not only the new one:
   `curl -s -o /dev/null -w '%{http_code}\n' https://<host>/` for each.
5. **Backups, if the platform owns them:** `projects/<name>/backup.sh` plus
   `<name>-backup.service` and `<name>-backup.timer` (unit names are
   host-global, so they carry the tenant's name), installed from the checkout
   into `/etc/systemd/system/`; any secret the backup needs goes in
   `projects/<name>/backup.enc.env` and is pushed to
   `/etc/platform/<name>/backup.env` (the steamlens README shows the flow).
   Not done until a restore has been verified.
6. **The private inventory:** any new secret gets its row (consumer · store ·
   path · rotation · if lost) in the stream's `secrets-inventory.md`.

## Removing a tenant

Reverse order: delete the tenant's directory (or one stanza from its `sites.caddy`), deploy
the proxy, verify the remaining hostnames, disable and remove its units,
delete the A record last (so no window exists where the record points at a
proxy that no longer knows the host).
