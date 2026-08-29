# Remote state: the one resource made by hand (2026-08-22, when the account was
# first set up), because Terraform cannot store its state in a bucket it has not
# created yet; adopted into this stack since (state_bucket.tf).
# Locking uses S3's own conditional writes (`use_lockfile`), so no DynamoDB table.
terraform {
  backend "s3" {
    bucket       = "leave-impact-tfstate-445743457479"
    key          = "leave-impact-agent/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
    encrypt      = true
  }
}
