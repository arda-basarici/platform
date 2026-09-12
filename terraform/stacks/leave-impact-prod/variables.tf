variable "alert_email" {
  description = "Recipient of every alert: budget thresholds, cost anomalies, the app host's status-check alarms (via the alerts topic)."
  type        = string
}

variable "app_hostname" {
  description = <<-EOT
    The Cloudflare-proxied hostname that fronts the instance. It appears in two
    places only (the Cloudflare A record and the instance's Caddyfile), so renaming
    later is cheap. Chosen 2026-08-26 as plumbing, not a public face — a demo-facing
    name can be added when the agent has something to show (its repository's DESIGN
    names that milestone) as a second record to the same origin.
  EOT
  type        = string
  default     = "leave-agent.ardabasarici.dev"
}

variable "instance_type" {
  description = "Application host size; the leave-impact-agent repository's DESIGN rules t4g.small (2 vCPU / 2 GB arm)."
  type        = string
  default     = "t4g.small"
}

# Cloudflare's published IPv4 egress ranges (cloudflare.com/ips-v4, fetched
# 2026-08-10) — the ONLY sources the security group admits on 443. This is the
# third pinned copy of the same list; the other two are the box's
# `box/firewall.sh` and its `box/Caddyfile` `trusted_proxies`. Pinned rather than
# fetched so a plan is reproducible offline and the firewall never changes
# without a deliberate edit; `scripts/check-cf-ranges.sh` keeps the three
# identical in ci and compares them with the published list weekly — a drift
# alarm there is the refresh trigger, all three together. IPv4 only, like the
# box: Cloudflare dials origins over v4 (the origin DNS record is an A record)
# and the instance publishes no v6 address.
variable "cloudflare_ipv4_ranges" {
  description = "Cloudflare edge IPv4 CIDRs allowed to reach the instance on 443."
  type        = list(string)
  default = [
    "173.245.48.0/20",
    "103.21.244.0/22",
    "103.22.200.0/22",
    "103.31.4.0/22",
    "141.101.64.0/18",
    "108.162.192.0/18",
    "190.93.240.0/20",
    "188.114.96.0/20",
    "197.234.240.0/22",
    "198.41.128.0/17",
    "162.158.0.0/15",
    "104.16.0.0/13",
    "104.24.0.0/14",
    "172.64.0.0/13",
    "131.0.72.0/22",
  ]
}

# The Bedrock lists, one per caller — inference-profile IDs (Frankfurt hosts
# current models only behind `eu.`/`global.` profiles). Model access in this
# account was opened through the console for every row below on 2026-08-26 and
# each passed the agent's exploratory probes from the instance role; the
# Claude 5 series stays account-gated and is not listed.
#
# The agent list is the catalogue the agent may pick from, not a choice: the
# choice waits for its model measurements on the hand-labelled evaluation set (a
# milestone its repository's VISION names). Re-cut 2026-09-09 (Sonnet 5 and Opus 5
# dropped); rows are dropped or added here when the measurement lands.
variable "bedrock_agent_models" {
  description = "Inference-profile IDs the instance role (the agent) may invoke."
  type        = list(string)
  default = [
    "eu.anthropic.claude-haiku-4-5-20251001-v1:0",
    "eu.anthropic.claude-sonnet-4-6",
    "eu.amazon.nova-lite-v1:0",
    "eu.amazon.nova-pro-v1:0",
    "eu.amazon.nova-2-lite-v1:0",
  ]
}

# The generator's pair: the prose writer and the checker that reads its output
# (the agent's DESIGN, the world generator). Granted to the generator role only.
variable "bedrock_generator_models" {
  description = "Inference-profile IDs the generator role may invoke."
  type        = list(string)
  default = [
    "eu.anthropic.claude-haiku-4-5-20251001-v1:0", # the prose writer
    "eu.amazon.nova-pro-v1:0",                     # the checker
  ]
}
