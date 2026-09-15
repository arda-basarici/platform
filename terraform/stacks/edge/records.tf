# Every record in the zone, as it stands (imported 2026-08-28, zero-diff).
#
# The A records are proxied and must stay proxied: a grey-cloud moment puts the origin
# address into passive-DNS archives permanently (box/README.md, Domain + TLS). ttl = 1
# is Cloudflare's "auto", the only value a proxied record accepts.
#
# The portfolio site (GitHub Pages) rides the apex and www CNAMEs DNS-only: GitHub
# terminates its own TLS and needs to see the visitor's request directly (the
# dashboard's "unproxied CNAME" insight is this, archived as accepted risk). The two TXT
# records are its domain proof and the Google Search Console verification — public
# DNS content, so they are literal here; the origin addresses are not.

locals {
  zone_id = data.cloudflare_zone.site.id
}

# --- the box (netcup): SteamLens and Frappe HR -----------------------------------

resource "cloudflare_dns_record" "steamlens" {
  zone_id = local.zone_id
  name    = "steamlens.${var.zone_name}"
  type    = "A"
  content = var.box_origin_ip
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "hr" {
  zone_id = local.zone_id
  name    = "hr.${var.zone_name}"
  type    = "A"
  content = var.box_origin_ip
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "hr_w1" {
  zone_id = local.zone_id
  name    = "hr-w1.${var.zone_name}"
  type    = "A"
  content = var.box_origin_ip
  proxied = true
  ttl     = 1
}

# --- the AWS app host: the leave-impact agent -------------------------------------

resource "cloudflare_dns_record" "leave_agent" {
  zone_id = local.zone_id
  name    = "leave-agent.${var.zone_name}"
  type    = "A"
  content = var.app_host_origin_ip
  proxied = true
  ttl     = 1
}

# --- the portfolio site (GitHub Pages) --------------------------------------------

resource "cloudflare_dns_record" "apex" {
  zone_id = local.zone_id
  name    = var.zone_name
  type    = "CNAME"
  content = "arda-basarici.github.io"
  proxied = false
  ttl     = 1
}

resource "cloudflare_dns_record" "www" {
  zone_id = local.zone_id
  name    = "www.${var.zone_name}"
  type    = "CNAME"
  content = "arda-basarici.github.io"
  proxied = false
  ttl     = 1
}

resource "cloudflare_dns_record" "google_site_verification" {
  zone_id = local.zone_id
  name    = var.zone_name
  type    = "TXT"
  content = "\"google-site-verification=ojo4nZceIw1nmOammFoqNBpAwbrOhdHP1GRfbnLcoeE\""
  proxied = false
  ttl     = 3600
}

resource "cloudflare_dns_record" "github_pages_challenge" {
  zone_id = local.zone_id
  name    = "_github-pages-challenge-arda-basarici.${var.zone_name}"
  type    = "TXT"
  content = "\"35030ef396a29e5b385323fcb48b7c\""
  proxied = false
  ttl     = 1
}

# --- no mail: the domain declares it sends and receives nothing ---------------------
# Without these, anyone can send "from" @ardabasarici.dev and most receivers will
# accept it. Null MX (RFC 7505) refuses delivery, SPF -all authorises no sender, and
# DMARC p=reject tells receivers to bin what fails; together they are the standard
# statement of a mail-less domain (2026-08-28).

resource "cloudflare_dns_record" "null_mx" {
  zone_id  = local.zone_id
  name     = var.zone_name
  type     = "MX"
  content  = "."
  priority = 0
  proxied  = false
  ttl      = 3600
}

resource "cloudflare_dns_record" "spf" {
  zone_id = local.zone_id
  name    = var.zone_name
  type    = "TXT"
  content = "\"v=spf1 -all\""
  proxied = false
  ttl     = 3600
}

resource "cloudflare_dns_record" "dmarc" {
  zone_id = local.zone_id
  name    = "_dmarc.${var.zone_name}"
  type    = "TXT"
  content = "\"v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s\""
  proxied = false
  ttl     = 3600
}
