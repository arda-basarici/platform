# leave-impact — platform adapter

The platform's side of the leave-impact agent. On the box: the site stanzas
for Frappe HR (the agent's dependency, run from that repository's
`deploy/frappe/`). On AWS: the agent's own host and deploy path, the
`terraform/stacks/leave-impact-prod/` stack (moved here from the agent
repository's `infra/` on 2026-08-27, zero-diff plan against the same state).

## Contract

| Value | Producer | Where it is used |
|---|---|---|
| `hr.ardabasarici.dev` | platform: Cloudflare A record (proxied) + a stanza in `sites.caddy` | the agent's configuration, the HR system's own site config |
| `hr-w3.ardabasarici.dev` (one hostname per world version — a world is one generated organization the agent plans over; the `Host` header selects the Frappe site. This one is the golden world's, added 2026-09-16: the world the agent is evaluated on and later serves, so the site lives until a later golden version replaces it) | platform: A record + a stanza in `sites.caddy`; a keyword uptime monitor (`pong` from `/api/method/ping`) raised with the site and deleted with it, by ruling: a served site | same; teardown removes the stanza, the record and the monitor with the site. The application's environment points at one world site at a time, its Frappe key pair replaced per site; a build site (raised to be read and dropped, as `hr-w2` was on 2026-09-15) carries no uptime monitor |
| upstream `frappe-frontend-1:8080` | application: the bench stack's frontend service on `web` | every stanza's `reverse_proxy` |
| the `web` network | platform | the bench stack joins it as external |
| no request-body cap, no proxy security headers | platform, by ruling in the stanzas: Frappe's nginx enforces its own 50m upload limit and already sends HSTS + nosniff | the application keeps sending them |
| `X-Forwarded-For` = the one verified visitor IP | platform | Frappe's own client-IP handling |
| deploy role `arn:aws:iam::445743457479:role/leave-agent-deploy` (GitHub OIDC trust pinned to the agent repository's `production` environment by numeric repository id; the branch restriction is the environment's own policy on GitHub's side) | platform stack: `deploy.tf` | the deploy workflow's `role-to-assume` |
| instance tag `Name=leave-agent-app` | platform stack: `instance.tf` | the deploy workflow finds the host by tag, so a replaced instance deploys without a workflow edit; the deploy role's `ssm:SendCommand` is also scoped to this tag |
| SSM prefix `/leave-agent/` (`origin-cert`, `origin-key`, `postgres-password`; names owned here, values put out-of-band) | platform stack: `secrets.tf` | the instance role's read policy; cloud-init and the deploy script read by name |
| `leave-agent.ardabasarici.dev` → the stack's Elastic IP (proxied A record) | platform: the stack's `app_hostname` variable + the Cloudflare record | cloud-init's Caddyfile on the host |
| Bedrock inference-profile shortlist for the agent | platform stack: `bedrock_agent_models` variable | the instance role's invoke policy; the agent picks from within it |
| Bedrock inference-profile pair for the world generator (the prose writer, the checker) | platform stack: `bedrock_generator_models` variable | the generator role's invoke policy |
| world bucket `leave-impact-world-445743457479` (application-readable in part) and truth bucket `leave-impact-truth-445743457479` (never application-readable); region `eu-central-1` | platform stack: `benchmark_buckets.tf` | the generator, the validator and the application as literal config; the truth bucket's unreachability from the instance is asserted by the application's own deploy step |
| prefixes, the contract's stable part: world bucket `worlds/<version>/…` (final, create-only) and `preparing/<version>/…` (mutable, never served); truth bucket `world-spec/<version>.json` and `truth-manifest/<version>.json` (final, create-only). `<version>` is the 64-hex digest the generator computes over the sealed artifacts; the file names under `worlds/<version>/` are the application's and may still move | application: its key layout; platform: the bucket policies that enforce it | every final object is written once, by a single `PutObject` carrying `If-None-Match: *` (a second write is refused with 412; a plain put with 403; server-side copies and multipart uploads into a final prefix are refused too). The validator's verdicts go under `worlds/<version>/verdicts/<run-id>-<run-attempt>.json`: a rerun shares the run id, and each execution's verdict is immutable |
| the truth bucket's read-denied canary, `access-probe/read-denied-canary` (a small fixed text object, the one platform-owned key in either bucket; outside the final prefixes because Terraform sends no `If-None-Match`) | platform stack: `benchmark_buckets.tf` | the read-denial probes. S3 hides existence: with ListBucket denied, a GET on an absent key is refused whether or not GetObject is granted, so a refused GET on this known key is the only proof of a GetObject denial. The application's deploy step targets it under the instance profile; the validator's own refusal check targets it too. The validator's `truth-manifest/` denial is proven against a real key (`truth-manifest/<version>.json`) once a world exists |
| generator role `arn:aws:iam::445743457479:role/leave-agent-generator` and validator role `arn:aws:iam::445743457479:role/leave-agent-validator` (GitHub OIDC trust pinned to the agent repository's `benchmark` environment by numeric repository id; the branch restriction and the required reviewer are the environment's own rules on GitHub's side, read back 2026-09-12: reviewer set, `main` only) | platform stack: `benchmark_roles.tf` | the generator and validator workflows' `role-to-assume`; sessions up to two hours. Nothing on the instance can assume either: the instance role reads `worlds/` and holds no assume-role grant |
| the runner's vendor credentials (the world site's Frappe API key and secret, the Jira token, the Google authorized-user JSON) | application: GitHub environment secrets on `benchmark`, guarded by the same reviewer gate as the roles; replaced per world site | the generator workflow; no AWS coupling, no SSM parameter, no platform grant |

## Files

| File | Role |
|---|---|
| `sites.caddy` | the stanzas: the production HR site, then the world site (`hr-w3`) |
| `../../terraform/stacks/leave-impact-prod/` | the AWS host: network, security group, instance role, instance + EIP + data volume, OIDC deploy role, parameter names, budget, cloud-init template; the benchmark's world and truth buckets with the generator and validator roles; and the remote-state bucket both stacks use, adopted into this one |

Stack commands run from the repository root with the Identity Center profile:
`AWS_PROFILE=leave-impact terraform -chdir=terraform/stacks/leave-impact-prod plan`.

Pending on the box, each on its trigger (ARCHITECTURE, the restraint list): the
MariaDB dump unit and its restore drill, once the agent's first generated world
is data worth keeping; Frappe's `.env` onto a SOPS file under this directory with
its own runtime recipient, at the next touch of its secrets.
