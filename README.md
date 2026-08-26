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

Status: design settled 2026-08-26; extraction in progress. Nothing here is deployed
from this repository yet.
