# The zone itself is hand-owned (created in the dashboard, its plan and account
# binding managed there). This stack owns what lives inside it: records and the
# settings that were deliberately set. Looking the zone up, rather than importing it,
# keeps its lifecycle out of Terraform's reach.
data "cloudflare_zone" "site" {
  filter = {
    name = var.zone_name
  }
}