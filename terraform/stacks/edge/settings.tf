# Only the settings that were deliberately set (the three carrying a modified_on in
# the settings API at the import, all 2026-08-09). Plan defaults stay absent: a
# setting appears here when it is changed from code, never because Cloudflare has a
# value for it.

# Cloudflare→origin over TLS, the origin's certificate verified: the Origin CA pair on
# each host is what makes "strict" hold (box/README.md, Domain + TLS).
resource "cloudflare_zone_setting" "ssl" {
  zone_id    = local.zone_id
  setting_id = "ssl"
  value      = "strict"
}

# The edge HTTP→HTTPS redirect; the hosts publish 443 only.
resource "cloudflare_zone_setting" "always_use_https" {
  zone_id    = local.zone_id
  setting_id = "always_use_https"
  value      = "on"
}

resource "cloudflare_zone_setting" "ipv6" {
  zone_id    = local.zone_id
  setting_id = "ipv6"
  value      = "on"
}