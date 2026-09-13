# Bot Fight Mode: on from the zone's creation, imported 2026-08-28 (zero-diff), turned
# off from here on 2026-09-14. The free plan's bot control is zone-wide, challenges
# on network reputation alone and has no exception mechanism (no WAF skip, no IP
# allowance): on 2026-09-13 it answered the first request from every cloud-network
# machine client of the world site, the app instance and a GitHub-hosted runner, with
# a managed challenge, while the workstation passed on the same user agents. The
# world site exists to be driven by machine clients, so the mode is the wrong control
# for this zone, not a nuisance. What still stands: the DDoS managed rulesets, the
# managed WAF ruleset, the exploit-path rule, the rate limit, and origins that admit
# Cloudflare's ranges only. The JS detection beacon goes with it: with the mode off
# it is a script injected into every HTML response for nothing. The AI-crawler
# controls stay at their defaults (disabled): the sites carry nothing worth protecting
# from training crawlers, and blocking them hides the portfolio from AI search. The
# resource stays so the state is readable from code and reversible from a plan.
resource "cloudflare_bot_management" "zone" {
  zone_id    = local.zone_id
  fight_mode = false
  enable_js  = false
}
