# Cloudflare Access in front of the Frappe hostnames (DESIGN, hosting: the Frappe
# login stops being scannable; the agent's own hostname stays ungated by ruling).
#
# Two trust paths on one application: machine clients present a service token in
# two headers (`CF-Access-Client-Id`, `CF-Access-Client-Secret`) under a Service
# Auth policy; a human browser logs in by one-time PIN under an Allow policy
# naming one address. Observed at the landing (2026-11-03): a request without a
# token, or with a wrong one, is answered 302 to the team domain's login page
# (`ardabasarici.cloudflareaccess.com`), never 401 or 403; a valid token is
# answered by Frappe, with an Access session cookie beside Frappe's own.
#
# The service token itself is minted in the dashboard, never here: its secret is
# server-generated, an output, so it cannot be write-only and a Terraform-created
# token would hold the secret in state. The policy names it through the data
# source, which carries the id and nothing secret. The token's values ride two
# SSM parameters (the leave-impact stack's secrets.tf) and two `benchmark`
# environment secrets, put out of band.
#
# The keyword monitors read `pong` from `/api/method/ping` on every world site: a
# second, path-scoped application carries a Bypass policy for that path so the
# monitors keep proving Frappe answers. The more specific path wins; the
# combination is proven by the probe, not by the docs.

locals {
  account_id = data.cloudflare_zone.site.account.id
  frappe_hostnames = [
    "hr.${var.zone_name}",
    "hr-w3.${var.zone_name}",
    "hr-w4.${var.zone_name}",
  ]
}

data "cloudflare_zero_trust_access_service_token" "machine_clients" {
  account_id = local.account_id
  filter = {
    name = "leave-agent-machine-clients"
  }
}

resource "cloudflare_zero_trust_access_policy" "frappe_machine_clients" {
  account_id = local.account_id
  name       = "frappe-machine-clients"
  decision   = "non_identity" # Service Auth: a service token, no identity login
  include = [{
    service_token = { token_id = data.cloudflare_zero_trust_access_service_token.machine_clients.id }
  }]
}

resource "cloudflare_zero_trust_access_policy" "frappe_operator" {
  account_id = local.account_id
  name       = "frappe-operator"
  decision   = "allow"
  include = [{
    email = { email = var.access_operator_email }
  }]
}

resource "cloudflare_zero_trust_access_policy" "frappe_ping_bypass" {
  account_id = local.account_id
  name       = "frappe-ping-bypass"
  decision   = "bypass"
  include    = [{ everyone = {} }]
}

resource "cloudflare_zero_trust_access_application" "frappe" {
  account_id   = local.account_id
  name         = "Frappe HR (world sites)"
  type         = "self_hosted"
  domain       = local.frappe_hostnames[0]
  destinations = [for h in local.frappe_hostnames : { type = "public", uri = h }]
  policies = [
    { id = cloudflare_zero_trust_access_policy.frappe_machine_clients.id, precedence = 1 },
    { id = cloudflare_zero_trust_access_policy.frappe_operator.id, precedence = 2 },
  ]
  app_launcher_visible = false
}

resource "cloudflare_zero_trust_access_application" "frappe_ping" {
  account_id   = local.account_id
  name         = "Frappe HR ping (uptime monitors)"
  type         = "self_hosted"
  domain       = "${local.frappe_hostnames[0]}/api/method/ping"
  destinations = [for h in local.frappe_hostnames : { type = "public", uri = "${h}/api/method/ping" }]
  policies = [
    { id = cloudflare_zero_trust_access_policy.frappe_ping_bypass.id, precedence = 1 },
  ]
  app_launcher_visible = false
}
