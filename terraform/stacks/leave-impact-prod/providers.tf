terraform {
  required_version = ">= 1.10" # S3-native state locking (`use_lockfile`)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Credentials come from the caller's environment (`AWS_PROFILE=leave-impact`, an
# Identity Center session) — never from this file. Every resource is tagged so the
# account stays sweepable by project and the cost pages can group by it.
provider "aws" {
  region = "eu-central-1"

  default_tags {
    tags = {
      project    = "leave-impact-agent"
      managed_by = "terraform"
    }
  }
}
