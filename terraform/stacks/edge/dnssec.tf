# DNSSEC signs the zone so a resolver can tell a forged answer from a real one; the
# proxied origins are hidden behind Cloudflare, but the name → edge binding itself was
# unsigned until this. Cloudflare signs; the chain of trust is completed by the DS
# record at the registrar (the `ds` output), after which `status` turns "active"
# (2026-08-28).
resource "cloudflare_zone_dnssec" "zone" {
  zone_id = local.zone_id
  status  = "active"
}
