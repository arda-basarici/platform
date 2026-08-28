variable "zone_name" {
  type    = string
  default = "ardabasarici.dev"
}

# Sensitive config, not secrets (SECRETS.md): never published, so no defaults — they
# come from the gitignored terraform.auto.tfvars.
variable "box_origin_ip" {
  description = "The netcup box's public IPv4 (SteamLens, Frappe HR)."
  type        = string
}

variable "app_host_origin_ip" {
  description = "The AWS app host's elastic IP (the leave-impact agent)."
  type        = string
}