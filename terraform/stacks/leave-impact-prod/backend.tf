# Remote state: the one resource made by hand (2026-08-22, aws-bootstrap probe),
# because Terraform cannot store its state in a bucket it has not created yet.
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
