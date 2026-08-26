# DESIGN — platform

The operational layer under the portfolio's deployed projects: the shared edge, the
hosts, the cloud resources, and the per-project wiring that joins an application to
them. One repository, owned by no application. This document holds the decisions and
their reasons; ARCHITECTURE.md holds how the system is built.

*Design draft · 2026-08-26 · not yet built.*

---

## Why this repository exists

steam-lens was the first service on the VPS, so its repository carried the host's
configuration: the Caddy proxy, the shared Docker network, the origin firewall, the
provisioning and hardening runbook. Reasonable with one tenant. The second tenant
(Frappe HR for the leave-impact agent, 2026-08-23) made the flaw observable: a
leave-impact ingress change was a commit in the steam-lens repository, and the box
Caddyfile now carried three stanzas from two projects. Meanwhile the leave-impact
agent's AWS stack was born as Terraform inside its own application repository, which
is fine until the second AWS stack arrives and the two share nothing.

The subsystem was already there; the second application made it visible. This
repository extracts it. The initial extraction adds no new production runtime
infrastructure: it centralizes what already exists and progressively codifies
procedures that today run by hand.

## The ownership line

**This repository owns infrastructure whose lifecycle crosses application boundaries
or is managed through an infrastructure/provider API. Application repositories own
their application artifacts and their runtime deployment procedure.**

Applied to what exists today:

| Concern | Owner |
|---|---|
| Host configuration on either host (Docker, hardening, firewall, backup framework; the box by runbook, the AWS host by cloud-init) | platform |
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
| The Frappe bench stack | it is a service on the box with its own Compose file | application (leave-impact repo) | Frappe HR is that agent's dependency, not a platform service; only its Caddy stanzas and its MariaDB dump unit are platform. Closes the "where does the Frappe stack live" question that repository's TODO carried |

**Secrets: standardize the policy, not the store.** Secret handling across the two
hosts had five mechanisms and no stated model (SOPS + age for steam-lens, a plain
box-side `.env` for Frappe, box config files for rclone and the origin certificate,
GitHub environment secrets for the deploy job, SSM Parameter Store on AWS). The
problem was the missing model, not the count: each runtime uses the store that matches
its native identity, and what is standardized is ownership, classification, recovery,
and handling. The full policy is `SECRETS.md`; the rulings that shape it:

| Rule | Why |
|---|---|
| Ownership follows the consumer: whoever needs the secret to do its job owns it | platform: the Origin CA pairs, the rclone token, the dead-man's-switch URL, deploy-boundary credentials · application: API keys, admin tokens, database passwords. Ownership and store are independent axes; the store is chosen afterwards by where the consumer runs |
| Store follows workload identity: AWS → SSM via the instance role · the box → SOPS + age · CI → OIDC, GitHub environment secrets only when a workflow itself needs the value · workstation → user environment variables | each store rides an identity the host already has; none needs a bootstrap credential |
| Three classes, and only the first is vaulted: *secret* (keys, passwords, private keys, tokens) · *sensitive config* (the origin address, account ids) · *normal config* (image digests, hostnames, parameter names, public keys) | otherwise "put anything operationally important in a vault" makes the system harder to reason about |
| Age recipients are scoped to the consumer: a recovery recipient, a platform-box recipient for `box/` and backup secrets, per-tenant runtime recipients only where a tenant must decrypt on its own | one host key that decrypts every tenant's file is convenience, not least privilege; a compromised host should read what it runs, not everything |
| An offline recovery recipient (password-manager-backed) is on every SOPS file | today one private key on one workstation is the only path to every encrypted value; losing it loses them. The highest-value fix in this whole topic |
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

**What this repository does not own:** anything an application could change without a
platform change. It never reaches into an application's Compose file, migrations, or
code. Ordinary application releases require no platform change; a feature that
changes an infrastructure contract (ingress, a new hostname, an upload-size cap,
networking, persistence, permissions) intentionally requires a change on both sides.
Adding a tenant is two changes on purpose: the application ships itself; the platform
wires it.

**The per-project directories are adapters, not generic platform.** `projects/steamlens/`
knows that steam-lens's durable state is one SQLite file; `projects/leave-impact/` knows
Frappe's nginx already sends HSTS. The layering is *shared platform → per-project
platform integration → application*, and the middle layer is allowed to know its
application. A later "clean-up" that makes the platform fully application-agnostic
would only push that knowledge back into the application repositories, which is the
split this repository exists to remove.

## The contract between the two sides

The application declares what it needs; the platform decides how the environment
provides it. The meeting point is a short list of named values, written down once in
`projects/<name>/README.md` and consumed by the application as configuration.

| Value | Producer | Consumer |
|---|---|---|
| Hostname (`steamlens.ardabasarici.dev`, `hr.`, `hr-w1.`) | platform: DNS record + site stanza | application README, links |
| Upstream endpoint (`steamlens-app-1:8000`, `frappe-frontend-1:8080`) | application: its Compose service name on the `web` network | platform: the stanza's `reverse_proxy` |
| The shared Docker network `web` | platform | every application stack joins it as external |
| Deploy role ARN (`arn:aws:iam::…:role/leave-agent-deploy`) | platform: `stacks/leave-impact-prod` | application workflow `role-to-assume` |
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
| shared platform | `box/`, later `ansible/` | rarely | every site on the host |
| per-project integration | `projects/<name>/` | often | one site |
| cloud resources | `terraform/stacks/<stack>/` | per stack | that stack's resources |

The full map with what each path holds and where each file lives today is
ARCHITECTURE's repository map; the mount-and-import mechanics that make "adding a
tenant is one directory" true are its tenant-seam section.

**Terraform state boundaries follow lifecycle and blast radius, not conceptual
similarity.** `edge` holds only Cloudflare: zone, records, edge settings. The AWS-side
GitHub OIDC *provider* and the deploy role's trust policy stay in `leave-impact-prod`
while that stack is the only consumer.

**Deliberately absent, and what would bring each in:**

| Absent | Appears when | Why not now |
|---|---|---|
| `modules/` (reusable Terraform) | a pattern repeats twice across stacks | one AWS stack and one edge exist; a module extracted from one example is a guess about the second. Same "contracts now, fields later" discipline steam-lens used |
| `<project>/<env>/` sub-levels | a second environment exists | one environment per project; the stack name carries it (`leave-impact-prod`) |
| a steam-lens Terraform stack | steam-lens acquires cloud resources | its API-managed pieces (the Cloudflare zone) are `edge`, not a per-project stack |
| `aws-foundation` (shared AWS: the OIDC provider, shared buckets) | a second AWS stack consumes the same resource | one consumer today |
| a `github` stack (environments, repository secrets) | there is a reason to manage them from code | none yet |

## Terraform: plan and apply stay on the laptop

Every stack keeps its own remote state (the state map is ARCHITECTURE's). Moving
`leave-impact-agent/infra/` here changes no backend key and no resource address, so
the acceptance test is exact: after `terraform init` in the new location,
`terraform plan` reports **0 to add, 0 to change, 0 to destroy**. Anything else stops
the migration until understood.

`plan` and `apply` stay laptop-side acts for now, as they are today. Repository CI
runs only what needs no credentials: `fmt -check`, `validate`, a static scanner. A CI
`plan` would need a read identity over state and every provider, and raw plan output
carries values and topology that do not belong in a public pull request; it arrives
once that identity and the output redaction are designed, and apply-from-CI behind an
approval gate (the way both applications deploy) after that. Neither is a day-one
requirement.

The GitHub OIDC trust pins the leave-impact repository's numeric identity in
`deploy.tf`. After the move, this repository's Terraform names another repository as
a trusted deploy principal; that is the intended shape (the platform grants, the
application assumes) and the role ARN is the published contract value.

## Pre-M1 scope and its backlog

Four steps, each shipping alone, then the leave-impact agent's M1 resumes:

| Step | Ships | Acceptance |
|---|---|---|
| 1. Found the repository | public from the first commit: gitignore + gitleaks hook first, these documents, `SECRETS.md` (the policy + the class-level inventory), the stream (with the exact inventory), the memory junction | first commit clean under the hook |
| 1b. The recovery recipient | a second age identity, private key in the password manager, added to the existing SOPS file (`sops updatekeys`) | the file decrypts with the recovery key alone, on a machine that never held the workstation key |
| 2. Extract the box layer from steam-lens | a split, not a move: the shared layer to `box/`, the site stanzas split into `projects/*/`, the backup units to `projects/steamlens/`; `deploy.sh` stays in steam-lens (deployment entrypoint). Platform-owned secret material (`BACKUP_PING_URL`, later the rclone token) moves with its consumer into a platform SOPS file; the application's keys stay in steam-lens's. One deploy of the proxy, old Caddyfile as the rollback | `steamlens.`, `hr.`, `hr-w1.` answer before anything is deleted from steam-lens; the glob import verified; afterwards steam-lens works without knowing leave-impact exists, leave-impact without steam-lens owning its ingress, and this repository is the only place that knows both |
| 3. Move the AWS stack | `infra/` → `terraform/stacks/leave-impact-prod/`; the contract values into `projects/leave-impact/README.md`; the application workflow's comment pointing here; then the secrets migration to `value_wo` (ARCHITECTURE, state map) | zero-diff plan for the move; for the migration, `terraform state pull` on the disposable experiment contains no secret, and the three production values still read back after it |
| 4. Ansible for the host | the box README transcribed into idempotent roles (docker, hardening, firewall, proxy, backups) | a throwaway VM, never the live box, reaches "both sites serve" from the playbook alone |

Step 4 is guarded: a two-day timebox, scope limited to transcribing the runbook that
exists (no new hardening, no new services); if the timebox blows, the work stops
where it is and becomes the first post-M1 platform milestone. It was ruled into
pre-M1 scope over the alternative of backlogging it: it answers host reproducibility,
a different problem from the cross-repo edit pain that triggered the extraction, and
the guard exists because that is exactly the shape of task that turns two days of
cleanup into a mini-project.

**Backlog** (the repository's TODO, not this document): the Cloudflare import into
`edge` · an authenticated CI `plan` (identity + redaction first), then apply-from-CI
behind an approval gate · SNS subscription for the AWS anomaly alert, state-bucket
adoption + `.tflock` lifecycle rule (carried over from the leave-impact TODO) ·
Dependabot for the pinned providers and actions · Frappe's box `.env` onto SOPS with its
own runtime recipient · PostgreSQL backup on the app host ·
the MariaDB dump unit and its restore drill · tenant handling on the AWS host (its
proxy config is baked into cloud-init today; decided when the leave-impact app's
first HTTP surface lands) · module extraction, when a pattern repeats.

## Reversals on record

| Was | Now | Why |
|---|---|---|
| Per-project stanzas shipped from each application repository (career stream ruling, 2026-08-23) | stanzas live here, under `projects/<name>/` (2026-08-26) | a stanza edits a shared process; owning it from five repositories reintroduces the cross-repo edit this repository exists to remove. Cost: the two-change tenant onboarding above, accepted |
| Ansible after M1 (first proposal, 2026-08-26) | pre-M1 step 4, timeboxed (same day) | post-milestone side-quests slip, and the transcription is cheapest while the runbook is in hand. Challenged again at review (a new capability, not an extraction); the timebox and transcription-only scope answer that challenge rather than dismiss it |
| CI runs `plan`, output in the pull request (first draft) | CI runs only credential-free checks; `plan` local | a CI plan needs a read identity over state and providers, and plan output leaks values into a public PR; design the identity first |

## Portfolio framing

This repository is evidence of how the projects are operated, not a third product
beside them. It earns a standalone page only if it accumulates the things that make
a platform substantial (several services, import history, rebuild automation, secret
policy, state separation, recovery drills, CI validation). The story it tells now is
the extraction itself: an abstraction that appeared under real pressure rather than
being designed in advance, consistent with the steam-lens ruling that infrastructure
appears only when a real system forces the question.
