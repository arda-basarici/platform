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
| `hr-w1.ardabasarici.dev` (one hostname per world version; the `Host` header selects the Frappe site) | platform: A record + a stanza in `sites.caddy` | same; teardown removes the stanza with the site |
| upstream `frappe-frontend-1:8080` | application: the bench stack's frontend service on `web` | both stanzas' `reverse_proxy` |
| the `web` network | platform | the bench stack joins it as external |
| no request-body cap, no proxy security headers | platform, by ruling in the stanzas: Frappe's nginx enforces its own 50m upload limit and already sends HSTS + nosniff | the application keeps sending them |
| `X-Forwarded-For` = the one verified visitor IP | platform | Frappe's own client-IP handling |
| deploy role `arn:aws:iam::445743457479:role/leave-agent-deploy` (GitHub OIDC trust pinned to the agent repository's `production` environment by numeric repository id; the branch restriction is the environment's own policy on GitHub's side) | platform stack: `deploy.tf` | the deploy workflow's `role-to-assume` |
| instance tag `Name=leave-agent-app` | platform stack: `instance.tf` | the deploy workflow finds the host by tag, so a replaced instance deploys without a workflow edit; the deploy role's `ssm:SendCommand` is also scoped to this tag |
| SSM prefix `/leave-agent/` (`origin-cert`, `origin-key`, `postgres-password`; names owned here, values put out-of-band) | platform stack: `secrets.tf` | the instance role's read policy; cloud-init and the deploy script read by name |
| `leave-agent.ardabasarici.dev` → the stack's Elastic IP (proxied A record) | platform: the stack's `app_hostname` variable + the Cloudflare record | cloud-init's Caddyfile on the host |
| Bedrock inference-profile shortlist | platform stack: `bedrock_models` variable | the instance role's invoke policy; the agent picks from within it |

## Files

| File | Role |
|---|---|
| `sites.caddy` | both stanzas: the production HR site, then world site 1 |
| `../../terraform/stacks/leave-impact-prod/` | the AWS host: network, security group, instance role, instance + EIP + data volume, OIDC deploy role, parameter names, budget, cloud-init template; and the remote-state bucket both stacks use, adopted into this one |

Stack commands run from the repository root with the Identity Center profile:
`AWS_PROFILE=leave-impact terraform -chdir=terraform/stacks/leave-impact-prod plan`.

Pending on the box, per the backlog: the MariaDB dump unit and its restore
drill; Frappe's `.env` onto a SOPS file under this directory with its own
runtime recipient.
