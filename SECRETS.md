# Secrets policy

What is standardized across every host and project is the *policy*: ownership,
classification, recovery, handling. The *store* is whichever one matches a runtime's
native identity, so no host needs a bootstrap credential to fetch its credentials.
The reasoning behind each rule is DESIGN.md's secrets section; this file is the
operating reference.

## Stores, by workload identity

| Runtime | Authentication path | Store | How a value gets there |
|---|---|---|---|
| AWS host | EC2 instance role | SSM Parameter Store (SecureString, standard tier) | `aws ssm put-parameter --overwrite --value file://…` from an admin terminal; never `--value` inline, never a Terraform variable |
| GitHub Actions → AWS | GitHub OIDC → STS | no long-lived AWS secret exists | — |
| GitHub Actions → the box | a forced-command ssh private key | GitHub environment secret (the one thing the workflow itself holds) | the environment's settings page |
| the box (netcup) | an age identity per consumer scope | SOPS-encrypted files in git (`*.enc.env`), decrypted to a chmod-600 `.env` beside the stack | `sops edit`; recipients per `.sops.yaml` |
| a workstation | the user | user environment variables | the `api-key-onboarding` ceremony: `Read-Host` → User env var, never a chat or transcript |
| Terraform | — | stores, paths, access policies, references only | a parameter's value is `value_wo` (write-only, never in state); the content is put out-of-band. If Terraform recreates a parameter, the placeholder is back: the production value is repopulated out-of-band before the dependent service counts as restored |

The AWS deploy path is the model case: no stored deploy credential at all. Where a
credential must be stored (the ssh key), it is scoped to one command on one host.

## Classes

| Class | Examples | Handling |
|---|---|---|
| **secret** | API keys, database passwords, private keys, tokens, OAuth refresh tokens | vaulted per the table above; never in a commit, a log, a chat, or intentionally copied into an infrastructure/config backup. Application data stores and their backups may themselves hold secret material and are protected accordingly |
| **sensitive config** | the box's origin address, account identifiers | not published, but not vaulted as if it were a credential; a GitHub environment secret or a private note is enough |
| **normal config** | image digests, hostnames, parameter *names*, public keys, host keys | committed where it is consumed |

Only the first class enters a store. Treating everything operationally important as a
secret makes the system harder to reason about.

## Ownership follows the consumer

Whoever needs the secret to perform its responsibility owns it: rotates it, knows what
happens if it is lost, keeps its recovery path. Store is chosen afterwards by where the
consumer runs.

| Secret class | Owner | Store |
|---|---|---|
| proxy TLS private material (Cloudflare Origin CA pairs) | platform | host-native: SSM on AWS, the box's `certs/` (re-issuable from the dashboard) |
| backup credentials (rclone token, the dead-man's-switch URL) | platform | box SOPS, platform recipient |
| deploy-boundary credentials (the forced-command ssh key) | platform | GitHub environment secret |
| application API credentials | the application | SOPS or SSM by host |
| application admin tokens | the application | SOPS or SSM by host |
| database credentials | the application | host-native store |

## Recipients (SOPS + age)

Recipients are scoped to the consumer, never one host key for everything:

- **recovery** — an identity whose private key lives outside the workstation, in the
  password manager, on every SOPS file. The guarantee is *workstation loss ≠ secret
  loss*; whether the copy is physically offline is a separate, later choice.
- **workstation** — the admin identity that edits files.
- **platform-box** — `box/` and backup secrets, once the box decrypts on its own.
- **`<tenant>`-runtime** — only where a tenant must decrypt autonomously; that recipient
  reads that tenant's file and nothing else.

## Rules

- No application secret is duplicated into GitHub.
- Production secret values never enter Terraform state.
- Backups exclude deployment secret material (`.env`, certificates, proxy state);
  database backups are themselves sensitive data.
- Every secret has a documented rotation and a documented "if lost" answer, in the
  exact inventory.
- The exact inventory (consumer · store · path · rotation · if lost) is not in this
  public repository; it lives in the private operational record. Secret *names* are
  not part of that boundary: SOPS encrypts values and leaves keys readable (that is
  what makes its diffs useful), so a public `*.enc.env` shows `SOME_API_KEY=ENC[…]`.
  Accepted: a name is not a credential, and name confidentiality is not a security
  boundary here.
