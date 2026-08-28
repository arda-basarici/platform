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

# SteamLens's /search is the one endpoint that does real work per request; the edge
# sheds a flood of it per client before the box sees it. Counted per source IP per
# colo (the free plan's fixed characteristics).
resource "cloudflare_ruleset" "ratelimit" {
  zone_id = local.zone_id
  name    = "default"
  kind    = "zone"
  phase   = "http_ratelimit"

  rules = [{
    description = "search flood shed"
    expression  = "(http.request.uri.path eq \"/search\")"
    action      = "block"
    enabled     = true

    ratelimit = {
      characteristics     = ["ip.src", "cf.colo.id"]
      period              = 10
      requests_per_period = 20
      mitigation_timeout  = 10
    }
  }]
}
