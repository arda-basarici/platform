# platform

The operational layer under the portfolio's deployed projects: the shared edge, the
hosts, the cloud resources, and the per-project wiring that joins an application to
them. One repository, owned by no application.

steam-lens was the first service on the VPS, so its repository carried the host's
configuration. When a second independent system arrived, that ownership stopped
making sense; this repository is the extracted shared layer with an explicit
application/platform boundary.

- `DESIGN.md` — the decisions and their reasons (ownership line, layout, secrets policy, scope).
- `ARCHITECTURE.md` — how it is built: the hosts, the paths a request / deploy / backup / change take, the repository and state maps.
- `SECRETS.md` — the secrets policy.

- `box/` — the shared layer on the VPS (proxy, firewall, runbook).
- `projects/<name>/` — one directory per tenant: site stanzas, backup units, contract.
- `terraform/stacks/<stack>/` — the cloud resources, one state per stack: the AWS app host (`leave-impact-prod`), the Cloudflare records and settings (`edge`).
- `runbooks/` — repeatable procedures, written as each is first exercised.

Status: design settled 2026-08-26; the box layer extracted from steam-lens on
2026-08-27, not yet deployed from this repository (the cutover is the next step).
