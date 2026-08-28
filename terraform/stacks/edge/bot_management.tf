# Bot Fight Mode, as it stands (imported 2026-08-28, zero-diff). The free plan's bot
# control: a challenge for traffic that scores as automated, plus the JS detection
# beacon it needs. It is here because it can challenge a legitimate client (an API
# caller, a monitor), so its state must be readable from code and reversible from a
# plan. The AI-crawler controls stay at their defaults (disabled): the sites carry
# nothing worth protecting from training crawlers, and blocking them hides the
# portfolio from AI search.
resource "cloudflare_bot_management" "zone" {
  zone_id    = local.zone_id
  fight_mode = true
  enable_js  = true
}
