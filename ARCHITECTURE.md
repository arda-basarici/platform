# ARCHITECTURE — platform

How the operational layer is built: the hosts, the paths a request / a deploy / a
backup / an infrastructure change take through it, the repository map, the state
map, and the seam between platform and application. The *why* behind each shape is
DESIGN.md's; this document describes the system as it stands.

*Snapshot of a system being extracted · last updated 2026-08-26 · describes the
running system and the target repository layout; the repository map's last column
says which files have moved.*

---

## The physical picture

Two hosts of the same shape, one per provider, each serving its own tenants behind
its own proxy. Nothing runs on both.

```mermaid
%%{init: {"flowchart": {"diagramPadding": 150}}}%%
flowchart TD
    V([visitor]) --> CF["`Cloudflare edge
    proxied DNS · SSL Full (strict) · bot cover`"]
    CF -->|"443, Cloudflare ranges only"| FW1["`the box (netcup, Debian)
    ufw: 22 only · DOCKER-USER chain
    admits Cloudflare ranges`"]
    CF -->|"443, Cloudflare ranges only"| FW2["`the app host (AWS EC2, AL2023 arm64)
    security group: 443 from Cloudflare
    no ssh · SSM Session Manager`"]
    FW1 --> C1["`Caddy — box-proxy stack
    Origin CA pair for *.ardabasarici.dev`"]
    FW2 --> C2["`Caddy — laid down by cloud-init
    Origin CA pair for this host, from SSM`"]
    C1 -->|"docker network web"| SL["`steamlens-app-1
    steam-lens repo`"]
    C1 -->|"docker network web"| FR["`frappe-frontend-1
    leave-impact repo, deploy/frappe`"]
    C2 -->|"docker network web"| LA["`leave-impact app + PostgreSQL
    leave-impact repo, deploy/instance`"]
    SL --> SLDB[("SQLite, bind-mounted")]
    FR --> FRDB[("MariaDB volume")]
    LA --> LADB[("PostgreSQL on the data volume")]
    SLDB -.->|"nightly, rclone"| DRIVE[("Google Drive")]
```

The rules that make them the same machine twice:

| Rule | On the box | On the app host |
|---|---|---|
| The origin answers only Cloudflare, only on 443 | DOCKER-USER chain from `firewall.sh`, applied each boot | security group ingress from Cloudflare's ranges |
| TLS at the origin is a Cloudflare Origin CA pair, never ACME | one pair for `*.ardabasarici.dev`, scp'd | one pair per host, read from SSM at boot |
| Caddy trusts `CF-Connecting-IP` only from a Cloudflare peer | global block `trusted_proxies` | same block |
| Applications join `web` as an external network and publish no port | `docker network create web` in the runbook | created by cloud-init |
| The proxy reaches an application by its Compose container name | `steamlens-app-1:8000`, `frappe-frontend-1:8080` | the app's service name |
| Administrative access | key-only ssh, root login off | no ssh; SSM Session Manager |

What differs is how each host came to exist: the box was provisioned by hand from the
runbook now in `box/README.md` (Ansible transcribes it, pre-M1 step 4); the app host is
`terraform apply` plus a first-boot script (`user_data.sh.tftpl`) that installs Docker
and a pinned Compose plugin, mounts the data volume, and starts the proxy. A replaced
instance serves a hello page until the next approved deploy lands the application.

## The four paths

**A request.** Visitor → Cloudflare edge (HTTP redirected to HTTPS there, bot
detection, caching) → origin over 443 with the edge as TCP peer → host firewall admits
it because the source is a Cloudflare range → Caddy terminates TLS with the origin
pair, matches the `Host` to a site stanza, sets the security headers and the
request-body cap the stanza declares, rewrites `X-Forwarded-For` to the single
verified visitor IP → `reverse_proxy` to the container name over `web` → the
application. A tenant's stanza is the only per-tenant part of that path; everything
before it is shared.

**An application deploy.** Two shapes, both gated by a GitHub `production`
environment with a required reviewer, both shipping an image tagged by the exact
commit CI tested:

```mermaid
%%{init: {"flowchart": {"diagramPadding": 150}}}%%
flowchart TD
    PUSH([push to main, either repo]) --> CI["`CI check + image
    pushed to GHCR, tagged by sha`"]
    CI --> GATE{{"`production environment
    required review — a human click`"}}
    GATE --> SSH["`steam-lens: forced-command ssh
    key may run /srv/steamlens/deploy.sh
    and nothing else`"]
    GATE --> OIDC["`leave-impact: OIDC → STS
    assumes leave-agent-deploy
    (stacks/leave-impact-prod)`"]
    SSH --> DS1["`deploy.sh on the box (steam-lens repo)
    pulls the sha, recreates the app,
    refuses while an analysis is live`"]
    OIDC --> SSM["`finds the instance by tag,
    ssm send-command with the script as payload`"]
    SSM --> DS2["`deploy/instance/deploy.sh (leave-impact repo)
    fetches that commit's compose.yaml,
    secrets from Parameter Store → env, compose up`"]
```

In both, the platform's part ends at the door: the ssh forced command on the box, the
OIDC provider + role + SSM permission on AWS. What runs behind the door is the
application's.

**A backup.** A systemd timer on the host runs a per-tenant script from
`projects/<name>/`. steam-lens's takes a WAL-safe `sqlite3 .backup`, integrity-checks
it before shipping (an unverified upload of a corrupt file preserves the corruption),
gzips, uploads to Drive with the host's rclone, prunes to 7 daily + 4 weekly, and
pings a healthchecks.io dead-man's switch. Backups exclude deployment secret material
by construction (`.env`, certificates, Caddy state: each regenerable from the
repositories or the dashboard); the database backups themselves are sensitive data
(an HR system's records, once Frappe's dump joins) and are treated as such when
encryption, retention, and restore access are decided. Frappe's MariaDB dump joins
the same framework (pending); the app host's PostgreSQL has no backup yet.

**An infrastructure change.**

```mermaid
%%{init: {"flowchart": {"diagramPadding": 150}}}%%
flowchart TD
    EDIT([edit in this repository]) --> PR["`pull request
    CI: terraform fmt -check · validate · static scan
    no credentials, no plan`"]
    PR --> MERGE([merge])
    MERGE --> TF["`Terraform stack:
    laptop — plan against remote state, read, apply`"]
    MERGE --> BOX["`box layer or a tenant stanza:
    git pull --ff-only in /srv/platform,
    caddy reload in the proxy container —
    Caddy validates the new config before
    replacing the old one`"]
    TF --> R1["blast radius: that stack"]
    BOX --> R2["blast radius: every site (box/) or one site (projects/)"]
```

## The edge, as it stands

Everything Cloudflare does for the zone, by who owns it. Read by API on 2026-08-28
(the inventory token) and kept current by the `edge` stack's plan.

**In code (`terraform/stacks/edge`).** The records above. Settings: `ssl = strict`,
`always_use_https`, `ipv6`, `min_tls_version = 1.2`, HSTS (`max_age` 86400 to start,
no subdomains, no preload; raised to six months once a canary period has passed) with
`nosniff`. One custom rule, `exploit-path noise` (blocks `.php`, `/wp-`, `/.env`,
`/.git` paths; 1 of the free plan's 5 slots). The one free rate-limiting rule, `client
flood shed`: 300 requests / 10 s per source IP per colo on every proxied host, verified
bots exempt, block for 10 s; a coarse ceiling on one client, tuned only from evidence.
Bot Fight Mode on with JS detections, the AI-crawler controls at their defaults.
DNSSEC signed (the DS record is the stack's `dnssec_ds` output).

**Cloudflare-managed, on by default, unmanaged on purpose.** The DDoS L7 ruleset,
the Managed Free WAF ruleset, URL normalization, TLS 1.3, post-quantum key exchange,
Encrypted Client Hello, HTTP/2 and HTTP/3, Brotli, Universal SSL (Google CA, apex +
wildcard), `security_level = medium`, the browser integrity check. A plan default is
not a decision; none of these appear in code until one is changed from code.

**Set by hand and recorded here, because no token or provider surface covers them.**
Two account-level notifications, both e-mail: Certificate Transparency Monitoring (a
certificate for the domain issued by any CA other than Cloudflare's own) and the
Universal SSL alert (issuance, renewal, validation failures). Account scope sits
outside both zone tokens, and two alert toggles do not justify a wider one. The
zone's `security.txt` (RFC 9116: the contact mailbox, languages en/tr, expires
2027-08-29 and must be renewed before then; served by Cloudflare at
`/.well-known/security.txt` on the proxied hosts only; provider 5.24 has no resource
for it). Two Security-page insights archived as accepted risk: the unproxied CNAMEs
(GitHub Pages terminates its own TLS) and AI Labyrinth (nothing to protect from AI
crawlers, and blocking them hides the portfolio from AI search).

**The constraint Bot Fight Mode imposes.** On the free plan it runs across the whole
zone, can challenge any automated client, and has no exception mechanism: a WAF skip
rule does not bypass it. Every machine client of a proxied hostname is therefore
tested, not assumed; the leave agent's Frappe REST probe has crossed it successfully,
which is an observation, not a guarantee. Super Bot Fight Mode (Pro) is the first
plan tier with exceptions, and that, not feature count, is the trigger for paying.

## Repository map

| Path | Holds | Lifecycle | Lives in (as of this snapshot) |
|---|---|---|---|
| `box/compose.yaml` | the proxy stack: Caddy, the `web` network declaration, mounts | slow | steam-lens `deploy/box/` → here (step 2) |
| `box/Caddyfile` | the global block only (trusted proxies, client-IP header) + `import /etc/caddy/projects/*/sites.caddy` | slow | steam-lens → here, split (step 2) |
| `box/firewall.sh`, `box/box-firewall.service` | the DOCKER-USER origin-only chain, applied each boot | slow | steam-lens → here (step 2) |
| `box/README.md` | provisioning + hardening runbook, until Ansible | slow | steam-lens → here (step 2) |
| `projects/steamlens/` | `sites.caddy` · `backup.sh` · `steamlens-backup.service` · `steamlens-backup.timer` (unit names are host-global, so they carry the tenant) · `backup.enc.env` (`BACKUP_PING_URL`) · README (contract values) | fast | steam-lens → here (step 2) |
| `projects/leave-impact/` | `sites.caddy` (the `hr` and `hr-w1` stanzas) · MariaDB dump units · README (contract values incl. the deploy role ARN) | fast | stanzas from steam-lens's Caddyfile (step 2); README's AWS rows (step 3) |
| `terraform/stacks/leave-impact-prod/` | VPC, subnet, IGW, route table · security group · instance role + profile (SSM core, parameter reads, Bedrock invoke) · the instance, its EIP, the data volume · the GitHub OIDC provider + deploy role · SSM parameter *names* · the monthly budget · `user_data.sh.tftpl` | per-stack | leave-impact-agent `infra/` → here, unchanged (step 3, 2026-08-27: zero-diff plan) |
| `terraform/stacks/edge/` | every DNS record of the zone (the four proxied A records, the portfolio site's CNAMEs and verification TXTs, the no-mail MX/SPF/DMARC) · the deliberately set zone settings (`ssl`, `always_use_https`, `ipv6`, `min_tls_version`, HSTS + nosniff) · the two security rulesets (custom rule, rate limit) · Bot Fight Mode · DNSSEC; the zone itself is a data lookup | per-stack | imported from the hand-made edge 2026-08-28 (records, settings, rulesets, bot control; every import zero-diff), then hardened from code the same day |
| `ansible/` | the box from bare metal | slow | not yet (step 4) |
| `runbooks/` | box-rebuild · add-a-tenant · deploy-edge-change · restore | — | new |

Everything on the application side of DESIGN's ownership table stays where it is;
the map above is the whole of what moves.

## State map

One remote state per stack, all in the S3 bucket bootstrapped by hand on 2026-08-22
outside the stacks whose state it stores (a backend has to exist before a stack can
initialize against it), locked with S3 conditional writes (`use_lockfile`), no
DynamoDB.

| Stack | Backend key | A bad apply breaks |
|---|---|---|
| `leave-impact-prod` | `leave-impact-agent/terraform.tfstate` (unchanged by the move) | the app host and its deploy path |
| `edge` | `edge/terraform.tfstate` | every hostname |

**Secret values and state.** The `aws_ssm_parameter` resources carry a placeholder
through the provider's write-only argument (`value_wo` + `value_wo_version`); the
provider sends it once and never reads the value back, so the real content, put
out-of-band from a terminal, never enters state. Proven 2026-08-27 on a disposable
parameter (create → apply → overwrite via the CLI → `apply -refresh-only` → `state
pull`: the marker string absent, `value` empty, only the version counter moved), then
applied to the three production parameters. Until that day the resources used
`value` + `ignore_changes = [value]`, which kept the value out of plans but not out
of state: refresh read the parameter decrypted and stored it marked sensitive, and
the state file did hold the certificate and the private key (verified by length
before the migration). The migration cleared them from the current state (serial
11 holds no key material); the state bucket's versioning is where old copies still
live, so expiring noncurrent versions moved up the backlog. Two facts govern any
future change here: the switch was an in-place update, not a replacement; and a
change to `value_wo_version` makes the next apply write the placeholder over the
real value, so the values are saved first and re-put right after, then read back.

## The box, on disk

This repository is checked out on the box at `/srv/platform` and is deployment
material only: no edits there, and a deploy is `git pull --ff-only` followed by
`caddy reload` in the proxy container (`compose up -d` only when the proxy's own
Compose file changed), so a checkout that diverged fails the deploy instead of
merging box-local state. The proxy mounts the `box/` directory, not the Caddyfile
alone: a single-file bind mount pins the inode and git replaces files by rename,
so the container would keep the pre-pull config (observed 2026-08-27). `git rev-parse HEAD` in it answers which
platform configuration is deployed (not which application images run; those are
the applications' deploys). Machine-local material lives outside the checkout
under `/etc/platform/`: `box/certs/` (the Origin CA pair), `<tenant>/` (files
decrypted from that tenant's `*.enc.env`, pushed from the workstation). Cloning
creates none of it; `box/README.md` provisions it. Applications keep their own
`/srv/<name>/` directories.

## The tenant seam, mechanically

A tenant is one directory under `projects/` and one line in the application's
Compose file (`networks: web: external: true`). The proxy mounts the checkout's
`projects/` read-only at `/etc/caddy/projects/` and the global Caddyfile imports
`*/sites.caddy`: one file per tenant holding all of its sites, because Caddy's
`import` accepts a single wildcard in its pattern (`*/*.caddy` is rejected at
adapt time; observed with `caddy validate` on 2.11.4 before the cutover, which is
what turned the first draft's per-hostname files into one file per tenant). A new
tenant's stanzas are live on the next `caddy reload` of the proxy without touching `box/` or
the proxy's Compose file. The values crossing the seam, and who produces each, are
DESIGN's contract table. The backup units follow the same pattern: the timer and
service under `projects/<name>/` are installed into `/etc/systemd/system/` by the
runbook (later the playbook), and the script they run, from the checkout, knows
that tenant's data.

## Open items visible from here

- The app host is single-tenant by ruling (DESIGN, ownership table): its proxy
  configuration is laid down by `user_data.sh.tftpl` inside `stacks/leave-impact-prod`,
  and the `projects/`-style adapter is extracted there only if a second tenant
  arrives. The Caddyfile flip from the hello page to the app, when its first HTTP
  surface lands, happens in that stack.
- PostgreSQL backup on the app host: none yet.
- The MariaDB dump unit and its restore drill: pending on the box.
- Security analytics on the free plan keep 24 hours; a decision that needs traffic
  evidence (widening the exploit-path rule, moving the rate-limit threshold) reads
  that window on the day, not a history.
