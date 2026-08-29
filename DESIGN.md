# DESIGN — platform

The operational layer under the portfolio's deployed projects: the shared edge, the
hosts, the cloud resources, and the per-project wiring that joins an application to
them. One repository, owned by no application. This document holds the decisions
and their reasons, as a narrative snapshot of the current design, edited in place;
the journey lives in the session log. How it is built → [ARCHITECTURE.md](ARCHITECTURE.md);
the pitch → [README.md](README.md).

*Snapshot of the built extraction · last updated 2026-08-29 · the four steps that
founded it have shipped; what remains is trigger-gated (the closing sections).*

---

## Objective

steam-lens was the first service on the VPS, so its repository carried the host's
configuration: the Caddy proxy, the shared Docker network, the origin firewall, the
provisioning and hardening runbook. Reasonable with one tenant. The second tenant
(Frappe HR for the leave-impact agent, 2026-08-23) made the flaw observable: a
leave-impact ingress change was a commit in the steam-lens repository, and the box
Caddyfile carried three stanzas from two projects. Meanwhile the leave-impact
agent's AWS stack was born as Terraform inside its own application repository,
which is fine until the second AWS stack arrives and the two share nothing.

The subsystem was already there; the second application made it visible. This
repository extracts it. The extraction itself added no new production runtime:
it centralized what already existed and codified procedures that had run by hand.
The edge step that followed used the same adoption process, then applied a small
set of deliberate hardening changes from code.

A valid outcome is exact: after the extraction, steam-lens works without knowing
leave-impact exists, leave-impact works without steam-lens owning its ingress, this
repository is the only place that knows both, and every hostname answers throughout
(the cutover itself cost one container recreate). For the code-managed resources the test is a zero-diff plan against the
same state; for the host, a blank machine reaching "the proxy serves every hostname"
from the playbook alone.

## The ownership line

**This repository owns infrastructure whose lifecycle crosses application boundaries
or is managed through an infrastructure/provider API. Application repositories own
their application artifacts and their runtime deployment procedure.**

Applied to what exists:

| Concern | Owner |
|---|---|
| Host configuration on either host (Docker, hardening, firewall, backup framework; the box by playbook, the AWS host by cloud-init) | platform |
| The proxy on either host: Caddy process, global Caddyfile, shared `web` network | platform |
| Per-project Caddy site stanzas on the multi-tenant box | platform (`projects/<name>/`) |
| The single-tenant AWS host's Caddy config (laid down by cloud-init) | platform (`stacks/leave-impact-prod`); the per-project adapter mechanism is extracted there only if that host gains a second tenant |
| Per-project host backup units (timer + service + the script they run) | platform (`projects/<name>/`) |
| Cloudflare DNS and edge configuration | platform |
| AWS resources (instance, network, IAM, SSM parameters, OIDC trust, budgets) | platform |
| Terraform state and backends | platform |
| Application image build, Dockerfile, CI | application |
| The application's own Compose stack (steam-lens app; the Frappe bench stack) | application |
| Database schema and migrations | application |
| The application's deployment entrypoint (`deploy.sh`, the only command its CI key may run) | application |
| Application runtime config and secret *values* (SOPS file, `.env`, the content of an SSM parameter) | application |
| Code that calls AWS (Bedrock, S3, SSM reads) | application |

The rule of thumb behind the AWS rows: a Terraform `resource` is infrastructure; an
SDK call is application. `aws_s3_bucket` lives here, `s3.put_object` does not.

**Two borderline placements, ruled:**

| Item | Pull toward the application | Ruling | Why |
|---|---|---|---|
| `backup.sh` | knows steam-lens internals (a WAL-safe `sqlite3 .backup`, the retention scheme) | platform, with its timer | it is a host operation on a tenant's data (systemd, the host's rclone, the host's dead-man's switch); splitting script from units would put one feature in two repositories |
| The Frappe bench stack | it is a service on the box with its own Compose file | application (leave-impact repo) | Frappe HR is that agent's dependency, not a platform service; only its Caddy stanzas and, when it exists, its MariaDB dump unit are platform |

**What this repository does not own:** anything an application could change without
a platform change. It never reaches into an application's Compose file, migrations,
or code. Ordinary application releases require no platform change; a feature that
changes an infrastructure contract (ingress, a new hostname, an upload-size cap,
networking, persistence, permissions) intentionally requires a change on both sides.
Adding a tenant is two changes on purpose: the application ships itself; the
platform wires it.

**The per-project directories are adapters, not generic platform.** `projects/steamlens/`
knows that steam-lens's durable state is one SQLite file; `projects/leave-impact/`
knows Frappe's nginx already sends HSTS. The layering is *shared platform →
per-project platform integration → application*, and the middle layer is allowed to
know its application. A later "clean-up" that makes the platform fully
application-agnostic would only push that knowledge back into the application
repositories, which is the split this repository exists to remove.

## Secrets: standardize the policy, not the store

Secret handling across the two hosts had five mechanisms and no stated model (SOPS +
age for steam-lens, a plain box-side `.env` for Frappe, box config files for rclone
and the origin certificate, GitHub environment secrets for the deploy job, SSM
Parameter Store on AWS). The problem was the missing model, not the count: each
runtime uses the store that matches its native identity, and what is standardized
is ownership, classification, recovery, and handling. The full policy is
[SECRETS.md](SECRETS.md); the rulings that shape it:

| Rule | Why |
|---|---|
| Ownership follows the consumer: whoever needs the secret to do its job owns it | platform: the Origin CA pairs, the rclone token, the dead-man's-switch URL, deploy-boundary credentials · application: API keys, admin tokens, database passwords. Ownership and store are independent axes; the store is chosen afterwards by where the consumer runs |
| Store follows workload identity: AWS → SSM via the instance role · the box → SOPS + age · CI → OIDC, GitHub environment secrets only when a workflow itself needs the value · workstation → user environment variables. Material that is re-issuable at will (the Origin CA pairs) is not vaulted at all: it lives host-native and is regenerated, not recovered | each store rides an identity the host already has; none needs a bootstrap credential |
| Three classes, and only the first is vaulted: *secret* (keys, passwords, private keys, tokens) · *sensitive config* (the origin address, account ids) · *normal config* (image digests, hostnames, parameter names, public keys) | otherwise "put anything operationally important in a vault" makes the system harder to reason about |
| Today every SOPS file has two recipients, the workstation and the recovery identity; no key lives on a host. If a host is ever to decrypt on its own, recipients are scoped by consumer (a platform-box recipient for `box/` and backup secrets, a per-tenant runtime recipient only where that tenant must decrypt autonomously), never one box-wide identity | one host key that decrypts every tenant's file is convenience, not least privilege; a compromised host should read what it runs, not everything |
| A recovery recipient, its private key in the password manager, is on every SOPS file | before it, one private key on one workstation was the only path to every encrypted value; losing it lost them. The highest-value fix in this whole topic, and the first thing shipped |
| Terraform owns stores, paths, policies and references; production secret values never enter state | the first draft assumed `ignore_changes = [value]` kept a value out of state; it does not (refresh still reads it). The write-only argument `value_wo` (Terraform ≥ 1.11, AWS provider 6.x) does; adopted at the AWS-stack move with its proof (ARCHITECTURE, the state map). State is a file, and this repository is public |
| No application secret is duplicated into GitHub | a workflow holds only what the workflow itself uses (the ssh deploy key) |
| The public repository carries the policy and a sanitized inventory by class; the exact inventory (name · consumer · store · path · recovery) lives in the private stream folder | architecture secrecy is not the security boundary, and there is still no reason to hand an attacker a complete operational map |

**Rejected: AWS Parameter Store for everything.** Possible, wrong trade. The box has no
AWS identity, so reading SSM from it means a long-lived IAM access key on the box (a
permanent credential whose job is fetching other credentials, exactly what the instance
role and OIDC exist to avoid) or IAM Roles Anywhere (a CA trust anchor, an X.509 client
identity, a credential helper: real mechanism so that netcup can ask AWS for the secrets
netcup needs). Either adds an AWS dependency to a host that could otherwise outlive the
account. Revisited only if the box starts consuming enough AWS services that an AWS
identity is independently useful. Same verdict, same reason, for a hosted manager
(Doppler, Infisical, Vault, 1Password Connect): an agent plus a bootstrap token on
every host, for two hosts. SOPS with a KMS key backend on the AWS host is the available
convergence path ("unify the tool, not the store") and is not a task while SSM works.

## The contract between the two sides

The application declares what it needs; the platform decides how the environment
provides it. The meeting point is a short list of named values, written down once in
`projects/<name>/README.md` and consumed by the application as configuration.

| Value | Producer | Consumer |
|---|---|---|
| Hostname (`steamlens.ardabasarici.dev`, `hr.`, `hr-w1.`, `leave-agent.`) | platform: DNS record + site stanza | application README, links |
| Upstream endpoint (`steamlens-app-1:8000`, `frappe-frontend-1:8080`) | application: its Compose service name on the `web` network | platform: the stanza's `reverse_proxy` |
| The shared Docker network `web` | platform | every application stack joins it as external |
| Deploy role ARN (`…:role/leave-agent-deploy`) | platform: `stacks/leave-impact-prod` | application workflow `role-to-assume` |
| The instance's `Name` tag, the SSM parameter prefix (`/leave-agent/`) | platform stack | application deployment entrypoint (finds the host, reads its secrets) |
| Durable-data path + what is and is not backed up | application: where its state lives | platform backup unit; the application README states the same |

Most values flow platform → application. Application-owned topology and storage
knowledge (the proxy upstream, the durable-data path) flow the other way: the
platform proxies to a container name the application chose and backs up a path the
application declared. Platform-internal values (the elastic IP feeding the Cloudflare
record, stack outputs consumed by another stack) are not part of this contract. A
rename on either side is a contract change and edits both READMEs.

## Layout: by lifecycle, then by project

Two organizing axes compete for the tenant artifacts: by service ("what does Caddy
serve", "what does the backup framework run") and by project ("everything about
steam-lens in one place"). The trigger for this repository was per-project locality,
so tenant artifacts group **by project**; the shared layer, which no single project
owns, groups **by service**. The deeper rationale is change lifecycle and blast radius
(the layered pattern platform teams converge on):

| Layer | Directory | Changes | A mistake breaks |
|---|---|---|---|
| shared platform | `box/`, `ansible/` | rarely | every site on the host |
| per-project integration | `projects/<name>/` | often | one site |
| cloud resources | `terraform/stacks/<stack>/` | per stack | that stack's resources |

The full map of what each path holds is ARCHITECTURE's repository map; the
mount-and-import mechanics that make "adding a tenant is one directory" true are
its tenant-seam section. One consequence of the mechanism, found when validation
refused a two-wildcard import: a tenant's sites live in one file
(`projects/<name>/sites.caddy`), not one file per hostname. The alternative that kept
per-hostname files, one import line per tenant in the global Caddyfile, would make
every new tenant an edit to `box/`, the cross-layer edit the seam exists to remove.

**On the box, the repository is the deployed configuration.** The box checks this
repository out at `/srv/platform` and the proxy runs from it; a box-layer deploy is
a fast-forward-only pull plus `caddy reload` (`compose up -d` only when the proxy's
Compose file itself changed). The alternative, copying files onto the box one `scp`
at a time (how steam-lens did it), leaves the box's real state unknowable from git;
a checkout makes "what is deployed" a commit hash. Two rules make it hold: the
checkout is never edited on the box, and cloning creates no runtime state.
Machine-local material (the Origin CA pair, decrypted per-tenant files) lives under
`/etc/platform/`, outside the checkout, so versioned configuration and mutable
secret material never share a directory; the playbook encodes the same split.

**Terraform state boundaries follow lifecycle and blast radius, not conceptual
similarity.** `edge` holds only Cloudflare: the records, the deliberately set
settings, the security rulesets, bot control and DNSSEC *inside* the zone. The zone
itself stays hand-owned and is looked up by name, never imported: managing it would
put the zone's own lifecycle within a `destroy`'s reach for no gain. A setting
appears in code only when it was deliberately set; a plan default is not a
decision, and coding it makes every future plan noisier. The adoption test for a
hand-made edge is therefore not "differs from the documented default" but "was it
set on purpose": Cloudflare stamps a hand-set setting with a `modified_on`
timestamp, and 3 of the zone's 56 settings carried one, exactly the three that had
been set at the first deploy. A non-default found without intent is a question, not
an import. The AWS-side GitHub OIDC *provider* and the deploy role's trust policy
stay in `leave-impact-prod` while that stack is the only consumer. The S3 state
bucket both stacks use is the shared Terraform backend, bootstrapped outside the
stacks whose state it stores and adopted into the AWS stack afterwards; a backend is
Terraform's own bootstrap, not a shared workload resource, so it does not count
toward the `aws-foundation` trigger below. What the zone tokens cannot reach
(account-level notifications) or the provider has no resource for (`security.txt`)
is set by hand and recorded in ARCHITECTURE with its values and the reason; a token
is not widened for a toggle.

**The edge divides abuse control by cost awareness.** The free plan's single
rate-limiting rule is the zone-wide ceiling on one abusive client, not a tenant's
endpoint limit: the edge cannot know what a request costs the origin, and spending
the one slot on one tenant's `/search` would leave every other host uncovered.
Endpoint-aware limits stay with the applications, which know their own costs
(steam-lens's own search limiter). The custom-rule slots
stay mostly empty for the same reason a plan default stays uncoded: a rule without
traffic evidence is a guess, and the free plan's analytics keep one day of it.

**Deliberately absent, and what would bring each in:**

| Absent | Appears when | Why not now |
|---|---|---|
| `modules/` (reusable Terraform) | a pattern repeats twice across stacks | one AWS stack and one edge exist; a module extracted from one example is a guess about the second. Same "contracts now, fields later" discipline steam-lens used |
| `<project>/<env>/` sub-levels | a second environment exists | one environment per project; the stack name carries it (`leave-impact-prod`) |
| a steam-lens Terraform stack | steam-lens acquires cloud resources | its API-managed pieces (the Cloudflare zone) are `edge`, not a per-project stack |
| `aws-foundation` (shared AWS: the OIDC provider, shared buckets) | a second AWS stack consumes the same resource | one consumer today |
| a `github` stack (environments, repository secrets) | there is a reason to manage them from code | none yet |
| a paid Cloudflare plan | an automated client of a proxied hostname needs an exception from Bot Fight Mode (Super Bot Fight Mode is the first tier with one) | every machine client has passed so far; "more features" is not a trigger |
| edge-wide response headers (a `http_response_headers_transform` ruleset) | a header every tenant should carry that the origins do not set | `nosniff` rides on the HSTS setting; `X-Frame-Options` / `Permissions-Policy` over Frappe untested; the tenant stanzas set their own |
| Authenticated Origin Pulls (mTLS edge → origin) | a second control on origin reachability is wanted | both origins already admit Cloudflare ranges only; defense in depth, not a hole |
| Cloudflare Access in front of `hr-w1` | its own design step | it adds a service-to-service trust boundary (the leave agent's machine path needs a service token), not a browser login toggle |
| IPv6 at the origins (v6 ranges in `trusted_proxies`, the firewalls, the security group) | an origin record becomes AAAA | Cloudflare dials an origin over the family of its record, and every origin record is an A record; a visitor's IPv6 ends at the edge (`ipv6 = on`). The box drops all forwarded v6 and the instance has no v6 address, so a v6 allowance today would admit no one. When the trigger fires, all three copies gain the `ips-v6` list together and `check-cf-ranges.sh` learns the second list |
| more custom rules (4 of 5 free slots empty) | the 24-hour security analytics show traffic a rule would address | `cf.threat_score` is retired (always 0); a rule without evidence is a guess |

## Terraform: plan and apply stay on the laptop

Every stack keeps its own remote state (the state map is ARCHITECTURE's). Moving a
stack into this repository changes no backend key and no resource address, so the
acceptance test is exact: after `terraform init` in the new location, `terraform
plan` reports **0 to add, 0 to change, 0 to destroy**. The same test governs
adopting a hand-made resource: the import lands, the plan goes quiet, and only
then does the resource change from code. Anything else stops until understood.

`plan` and `apply` are laptop-side acts. Repository CI runs only what needs no
credentials: a full-history secret scan, `fmt -check`, and a per-stack `validate`
against a read-only lock file. A CI `plan` would need a read identity over state
and every provider, and raw plan output carries values and topology that do not
belong in a public pull request; it arrives once that identity and the output
redaction are designed, and apply-from-CI behind an approval gate (the way both
applications deploy) after that. Neither is a day-one requirement, and neither has
a trigger while one person applies from one laptop.

The GitHub OIDC trust pins the leave-impact repository's numeric identity in
`deploy.tf`. This repository's Terraform names another repository as a trusted
deploy principal; that is the intended shape (the platform grants, the application
assumes) and the role ARN is the published contract value.

## The extraction, in four steps

The leave-impact agent's first build milestone was deliberately held until the
platform existed, so the extraction had a fixed scope and an order: each step
shipping alone, each with an acceptance stated before it started.

| Step | Shipped | Acceptance, and how it held |
|---|---|---|
| 1. Found the repository | 2026-08-26: public from the first commit, gitignore + the gitleaks hook first, these documents, `SECRETS.md`, the private stream with the exact inventory | the first commit clean under the hook |
| 1b. The recovery recipient | 2026-08-27: a second age identity, private key in the password manager, added to the existing SOPS file | the file decrypts with the recovery key alone |
| 2. Extract the box layer from steam-lens | 2026-08-27: a split, not a move; the shared layer to `box/`, the site stanzas to `projects/*/sites.caddy`, the backup units and `BACKUP_PING_URL` to `projects/steamlens/`; `deploy.sh` stayed in steam-lens (deployment entrypoint); one deploy of the proxy with the old Caddyfile as the rollback | `steamlens.`, `hr.`, `hr-w1.` answered before anything was deleted from steam-lens; the import glob verified (and corrected, the one-wildcard finding above); afterwards each application repository knows only itself |
| 3. Move the AWS stack | 2026-08-27: `infra/` → `terraform/stacks/leave-impact-prod/`, the contract values into `projects/leave-impact/README.md`, the application workflow pointing here; then the `value_wo` migration; then (2026-08-28) the state bucket adopted into the stack | zero-diff plan for the move; the state-pull proof for the migration (ARCHITECTURE, the state map), the three production values reading back afterwards; zero-diff for the bucket |
| 4. Ansible for the host | 2026-08-28: `box/README.md` transcribed into five roles and an acceptance script | a blank cloud host reached a passing `verify.sh` from the playbook alone |
| 4b. The edge into code | 2026-08-28: every record, the deliberately set settings, the two hand-made rulesets and Bot Fight Mode imported; then TLS 1.2, DNSSEC, HSTS, the no-mail records applied from code | every import `N to import, 0 to add, 0 to change, 0 to destroy`, then `No changes`; every hardening applied verified live (a TLS 1.0 handshake refused; the zone signed at Cloudflare, the DS record not yet at the `.dev` registry when last read on 2026-08-29) |

The edge step was not in the original four; it entered when the extraction of the
box made the one remaining hand-made layer conspicuous, and it followed the same
adoption test as the AWS move.

**The playbook's rulings.** The Ansible step was guarded before it started: a
two-day timebox, scope limited to transcribing the runbook that existed (no new
hardening, no new services), and if the timebox blew the work would stop where it
was and become the first later platform milestone. It was ruled into the extraction
over backlogging it because it answers host reproducibility, a different problem
from the cross-repo edit pain that triggered the extraction, and the transcription
is cheapest while the runbook is in hand; the guard exists because that is exactly
the shape of task that turns two days of cleanup into a mini-project. The rulings
that shaped the build:

- *Test host:* a hand-launched throwaway EC2 instance (Debian 12, the leave-impact
  region), never in a stack's state, terminated on acceptance; a fresh instance is
  the blank host on every run. A local Hyper-V VM was the alternative; the cloud
  host wins because the firewall check from the workstation then runs from the real
  internet. Cheap to change.
- *Acceptance, made precise:* the runbook stops at the proxy and the applications
  are deployed by their own repositories, so "both sites serve" on a host that has
  no application means: Caddy answers every hostname over the installed origin cert
  (a 502 is a pass, the upstream is absent by design), and every other runbook
  section verifies. `ansible/verify.sh` is that checklist. A stub upstream for a
  200 was rejected: it proves nothing the 502 does not and adds test-only material
  to the roles.
- *Roles:* one per runbook section, run in a fixed order because they depend on
  each other (`hardening` → `docker` → `firewall` → `proxy` → `backups`); a failure
  names its section. `hardening` allows 22 before enabling ufw and checks the
  connection survives the sshd reload. rclone's Drive OAuth stays a manual step; the
  role verifies the remote exists and fails pointing at the README, warning instead
  on a test host that has no token. `proxy` stays broad until pressure splits it.
  Two adjustments came from the build: `firewall` makes the `/srv/platform`
  checkout as its first consumer, so `proxy` finds it present; and `firewall.sh`
  takes its uplink from an `IFACE` variable (default `eth0`, the box), set through a
  systemd drop-in only on a host whose interface is named otherwise, found when the
  test host's `ens5` left the rules matching nothing and the bare IP answering.
- *The origin cert pair:* copied from a workstation path outside the repository,
  the same handling as the runbook's `scp`; no vault, no SOPS (re-issuable from the
  dashboard, nothing to back up). The test host gets a self-signed pair; the real
  key never leaves the workstation for a test.
- *Control node:* a Unix-like control node, today WSL, with a dedicated key
  generated there (never under the repository tree), a gitignored local inventory
  and a committed example. The live box, when it is a target, is addressed by its
  ssh alias so the origin IP stays out of the public repository.

## Decisions that changed, and why

| Was | Now | Why |
|---|---|---|
| Per-project stanzas shipped from each application repository (the first ruling, before this repository existed) | stanzas live here, under `projects/<name>/` | a stanza edits a shared process; owning it from every application repository reintroduces the cross-repo edit this repository exists to remove. Cost: the two-change tenant onboarding above, accepted |
| Ansible after the leave agent's first milestone (first proposal) | part of the extraction, timeboxed | post-milestone side-quests slip, and the transcription is cheapest while the runbook is in hand. Challenged again at review (a new capability, not an extraction); the timebox and transcription-only scope answer that challenge rather than dismiss it |
| CI runs `plan`, output in the pull request (first draft) | CI runs only credential-free checks; `plan` local | a CI plan needs a read identity over state and providers, and plan output leaks values into a public PR; design the identity first |
| Every non-default edge setting into code (first inventory pass) | only deliberately set settings, found by their `modified_on` stamp | a non-default with no intent behind it is a question, not a decision; coding it would freeze an accident |
| The rate limit as steam-lens's `/search` guard (the hand-made rule) | the zone-wide client ceiling; `/search` left to the application's own limiter | the free plan has one slot, and the edge cannot price an endpoint; the application can |

## Scope and non-goals

- In: the two hosts and what makes them the same machine twice; the Cloudflare
  zone's contents; the AWS resources the leave-impact agent runs on; the per-tenant
  wiring; the secrets policy; the host from a blank machine.
- Deliberately out: anything on the application side of the ownership table; a
  generic, application-agnostic platform (the adapters are allowed to know their
  tenant); a product of its own. This repository is evidence of how the projects are
  operated, not a third project beside them, and it earns more only by accumulating
  operation (rebuild automation, import history, recovery drills, CI validation),
  never by decoration.

## Future work, by trigger

The "deliberately absent" table above carries the structural triggers. Beyond it:

- **Backups for the other two databases** (Frappe's MariaDB dump unit under
  `projects/leave-impact/`, PostgreSQL on the app host) and the restore drill that
  makes a backup real: when there is data worth keeping, i.e. the leave-impact
  agent's first generated world.
- **Replaying the playbook against the live box**: at the first rebuild, or when a
  `box/` change is large enough that hand-applying it is the riskier path.
- **A platform-box age recipient**, so the box decrypts its own files, and Frappe's
  box `.env` onto SOPS with its own runtime recipient: when the workstation-push
  path becomes the bottleneck, since the change moves the host-compromise boundary.
- **Authenticated CI `plan`**, then apply-from-CI behind an approval gate: when a
  second person applies, or the first stops applying from a laptop.
- **HSTS to six months** on the zone: after a canary week with nothing broken
  (the day-long value was applied 2026-08-28).
- **The runbooks not yet written** (box rebuild, restore, instance replacement on
  the app host): written the first time each is exercised, never ahead of it.
- **A host-up signal, then minimal observability**: one external HTTPS monitor per
  hostname first (it also answers whether Bot Fight Mode challenges machine
  clients, the paid-plan trigger); then EC2 status-check alarms with auto-recover
  and a subscribed recipient, and Docker log rotation on the next controlled
  recreate. Nothing here is gated on the application.
- **CI over every configuration kind, still credential-free**: an Ansible syntax
  check, ShellCheck on the scripts, `caddy validate` on the assembled proxy layout,
  a drift check of the pinned Cloudflare ranges against the published lists,
  Actions pinned by commit. The guard is "what can reach a host unchecked", not a
  lint suite.
- **The playbook against the live box, in two steps**: a `--check --diff` run
  first, its differences classified (intended, unintended, not representable in
  check mode) and recorded as summaries, then the replay itself on an operational
  reason (a rebuild, or a `box/` change large enough that hand-applying it is the
  riskier path).
- **Evidence as committed record, not narration**: dated summaries of the zero-diff
  plans, the `verify.sh` passes and the check-mode outcome, never raw plan or
  transcript output, which carries topology.
- **The rebuild-and-restore drill**, once the restore of the SteamLens backup has
  been exercised by hand: blank host → play → `verify.sh` → the application via its
  own deploy path → a real restore, timed; its runbook written during it. The
  strongest evidence this repository can add.
- **Per-tenant proxy networks** (one per tenant, Caddy joining all, each tenant
  only its own; one line per application repository): at the next proxy recreate,
  paired with hardening the Caddy container, since the proxy is the pivot between
  tenants. No trigger: the HR system's data already justifies it.
- **Private connectivity between the hosts**, the leave agent to Frappe first: a
  design step of its own at the first cross-host call that should not ride the
  public edge, the mechanism (public edge + application auth, mTLS, WireGuard, a
  mesh, Cloudflare's private network) chosen then. An inbound Cloudflare Tunnel was
  considered and dropped: it substitutes for the "443 from Cloudflare ranges"
  clause rather than adding to it, and the origin-side question reopens only if
  this design lands on Cloudflare Zero Trust.
- **Security depth before the agent's real HTTP surface**: the instance role's
  read scope narrowed (every container reaches the role through IMDS, and Bedrock
  needs that), a custom SSM document replacing `AWS-RunShellScript` for the deploy
  role, a signed or commit-pinned checkout for the root-run `firewall.sh` pull.
