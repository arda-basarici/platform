# leave-impact — platform adapter

The platform's side of the leave-impact agent. On the box: the site stanzas
for Frappe HR (the agent's dependency, run from that repository's
`deploy/frappe/`). On AWS: the agent's own host and deploy path, in
`terraform/stacks/leave-impact-prod/` once the stack moves here (pre-M1
step 3); the AWS rows of the contract fill in then.

## Contract

| Value | Producer | Where it is used |
|---|---|---|
| `hr.ardabasarici.dev` | platform: Cloudflare A record (proxied) + a stanza in `sites.caddy` | the agent's configuration, the HR system's own site config |
| `hr-w1.ardabasarici.dev` (one hostname per world version; the `Host` header selects the Frappe site) | platform: A record + a stanza in `sites.caddy` | same; teardown removes the stanza with the site |
| upstream `frappe-frontend-1:8080` | application: the bench stack's frontend service on `web` | both stanzas' `reverse_proxy` |
| the `web` network | platform | the bench stack joins it as external |
| no request-body cap, no proxy security headers | platform, by ruling in the stanzas: Frappe's nginx enforces its own 50m upload limit and already sends HSTS + nosniff | the application keeps sending them |
| `X-Forwarded-For` = the one verified visitor IP | platform | Frappe's own client-IP handling |
| deploy role ARN · instance `Name` tag · SSM prefix `/leave-agent/` | platform stack | the agent's deploy workflow (step 3) |

## Files

| File | Role |
|---|---|
| `sites.caddy` | both stanzas: the production HR site, then world site 1 |

Pending on the box, per the backlog: the MariaDB dump unit and its restore
drill; Frappe's `.env` onto a SOPS file under this directory with its own
runtime recipient.
