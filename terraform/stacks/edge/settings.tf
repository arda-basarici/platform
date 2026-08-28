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

# --- changed from code (each its own apply from a trusted plan) --------------------

# Nothing legitimate speaks TLS 1.0/1.1 any more; Cloudflare's default floor of 1.0
# only widens the cipher surface (2026-08-28).
resource "cloudflare_zone_setting" "min_tls_version" {
  zone_id    = local.zone_id
  setting_id = "min_tls_version"
  value      = "1.2"
}

# HSTS: a browser that has seen it refuses plain HTTP to the host for max_age seconds,
# so the value is a commitment with a memory. It starts at one day and is raised (to
# six months) once nothing has broken; no includeSubDomains (the apex is GitHub Pages
# and does not pass the edge), no preload (irreversible in practice). nosniff rides on
# the same setting: browsers must honour the origin's Content-Type (2026-08-28).
resource "cloudflare_zone_setting" "security_header" {
  zone_id    = local.zone_id
  setting_id = "security_header"
  value = {
    strict_transport_security = {
      enabled            = true
      max_age            = 86400
      include_subdomains = false
      preload            = false
      nosniff            = true
    }
  }
}
