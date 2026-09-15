# DNSSEC signs the zone so a resolver can tell a forged answer from a real one; the
# proxied origins are hidden behind Cloudflare, but the name → edge binding itself was
# unsigned until this. Cloudflare signs (applied 2026-08-28); the chain of trust is
# completed only when the DS record (the `dnssec_ds` output) sits at the `.dev` registry.
# Read live on 2026-09-15: the DS at the `.dev` parent (registry RDAP `delegationSigned
# true`), answers validated (`AD`) at two public resolvers; the chain is complete. It
# landed by 2026-09-14, seventeen days after the enable (absent on a 2026-09-13 read),
# through Cloudflare Registrar's automatic submission. `status` here is the request, not the proof: a DS query against the
# parent is.
resource "cloudflare_zone_dnssec" "zone" {
  zone_id = local.zone_id
  status  = "active"
}
