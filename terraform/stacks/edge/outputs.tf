output "zone_id" {
  value = local.zone_id
}

# The DS record the registrar holds for the zone (at the `.dev` parent since 2026-09-14);
# a DS query against the parent must return exactly this.
output "dnssec_ds" {
  value = cloudflare_zone_dnssec.zone.ds
}
