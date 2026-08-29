variable "alert_email" {
  description = "Recipient of budget and anomaly alerts."
  type        = string
}

variable "app_hostname" {
  description = <<-EOT
    The Cloudflare-proxied hostname that fronts the instance. It appears in two
    places only (the Cloudflare A record and the instance's Caddyfile), so renaming
    later is cheap. Chosen 2026-08-26 as plumbing, not a public face — a demo-facing
    name can be added at the agent's demo milestone as a second record to the same
    origin.
  EOT
  type        = string
  default     = "leave-agent.ardabasarici.dev"
}

variable "instance_type" {
  description = "Application host size; the DESIGN ruling is t4g.small (2 vCPU / 2 GB arm)."
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

# The Bedrock shortlist the instance role may invoke — inference-profile IDs
# (Frankfurt hosts current models only behind `eu.`/`global.` profiles). This is
# the catalogue from the agent's probe days, not a choice: the choice waits for
# the investigator milestone's measurements on the golden set (the agent
# repository's VISION names the milestones), and rows are dropped or added here
# when it lands.
variable "bedrock_models" {
  description = "Inference-profile IDs the instance role may invoke."
  type        = list(string)
  default = [
    "eu.anthropic.claude-haiku-4-5-20251001-v1:0",
    "eu.anthropic.claude-sonnet-5",
    "eu.anthropic.claude-opus-5",
    "eu.anthropic.claude-sonnet-4-6", # the Anthropic row this account can call today (2026-08-26)
    "eu.amazon.nova-lite-v1:0",
    "eu.amazon.nova-pro-v1:0",
    "eu.amazon.nova-2-lite-v1:0",
  ]
}
