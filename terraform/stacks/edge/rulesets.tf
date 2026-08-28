# The zone's two hand-made security rules, as they stand (imported 2026-08-28,
# zero-diff). Cloudflare holds one ruleset per phase and zone; each of these is that
# phase's single "default" ruleset, so a rule change here is a change to the live edge.
# They were found after the records/settings import: the token could not read
# rulesets, and the by-eye check covered the Rules page, not Security.

# Drops the scanner background noise before it reaches an origin: none of the tenants
# serves PHP, WordPress, or dotfiles, so any such path is an exploit probe.
resource "cloudflare_ruleset" "firewall_custom" {
  zone_id = local.zone_id
  name    = "default"
  kind    = "zone"
  phase   = "http_request_firewall_custom"

  rules = [{
    description = "exploit-path noise"
    expression  = "(http.request.uri.path contains \".php\") or (http.request.uri.path contains \"/wp-\") or (http.request.uri.path contains \"/.env\") or (http.request.uri.path contains \"/.git\")"
    action      = "block"
    enabled     = true
  }]
}

# The zone-wide ceiling on one client (the free plan allows a single rate-limiting
# rule, so it is spent on the general case, not on one tenant's endpoint). The layers
# above and below it: the DDoS L7 managed ruleset takes volumetric floods; an endpoint
# that needs a tighter budget limits itself (SteamLens's /search has its own per-IP
# cap answering 429). Loose on purpose: an office NAT shares one ip.src across every
# Frappe HR user, and one HR page load is dozens of requests. Counted per source IP
# per colo (the free plan's fixed characteristics). Only the proxied hosts pass
# through here; the apex and www go DNS-only to GitHub Pages.
resource "cloudflare_ruleset" "ratelimit" {
  zone_id = local.zone_id
  name    = "default"
  kind    = "zone"
  phase   = "http_ratelimit"

  rules = [{
    description = "client flood shed"
    expression  = "(http.host contains \"${var.zone_name}\")"
    action      = "block"
    enabled     = true

    ratelimit = {
      characteristics     = ["ip.src", "cf.colo.id"]
      period              = 10
      requests_per_period = 300
      mitigation_timeout  = 10
    }
  }]
}
