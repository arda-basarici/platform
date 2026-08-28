output "zone_id" {
  value = local.zone_id
}

# The DS record to place at the registrar; DNSSEC completes when it is there.
output "dnssec_ds" {
  value = cloudflare_zone_dnssec.zone.ds
}
