# The shared Terraform backend, bootstrapped outside the stacks whose state it stores
# (the bucket was made by hand for leave-impact-prod, 2026-08-22, and adopted there).
# Its own key: edge and the AWS stack have separate lifecycles.
terraform {
  backend "s3" {
    bucket       = "leave-impact-tfstate-445743457479"
    key          = "edge/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
    encrypt      = true
  }
}