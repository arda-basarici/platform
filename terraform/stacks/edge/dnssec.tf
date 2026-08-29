# DNSSEC signs the zone so a resolver can tell a forged answer from a real one; the
# proxied origins are hidden behind Cloudflare, but the name → edge binding itself was
# unsigned until this. Cloudflare signs (applied 2026-08-28); the chain of trust is
# completed only when the DS record (the `ds` output) sits at the `.dev` registry.
# Read live on 2026-08-29: the zone signed, no DS at the parent, answers unvalidated;
# the registrar step is still pending. `status` here is the request, not the proof:
# a DS query against the parent is.
resource "cloudflare_zone_dnssec" "zone" {
  zone_id = local.zone_id
  status  = "active"
}
