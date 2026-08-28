terraform {
  required_version = ">= 1.10" # S3-native state locking (use_lockfile)

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

# Credentials come from the caller's environment (CLOUDFLARE_API_TOKEN, a token
# scoped to this one zone: Zone Read, DNS Edit, Zone Settings Edit) — never from this
# file, never a variable. Plan and apply are laptop-side only (the plan output carries
# the origin addresses).
provider "cloudflare" {}