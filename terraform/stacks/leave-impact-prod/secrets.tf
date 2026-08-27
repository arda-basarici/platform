# Secrets ride SSM Parameter Store (SecureString, standard tier — free), the
# ruling over SOPS for the AWS side: the instance role reads by path, nothing
# lives on the workstation or in git, every read is a CloudTrail event.
#
# Terraform owns the parameters' existence and names; it never owns their
# values. Each is created with a placeholder and `ignore_changes` on the value,
# so the real content is put out-of-band from Arda's terminal
# (`aws ssm put-parameter --overwrite --value file://…`) and no later apply can
# revert it. The pair is a Cloudflare Origin CA certificate issued for this
# host alone — never the box's pair copied over: one pair per host, revocable
# independently.
locals {
  secret_names = {
    origin_cert       = "/leave-agent/origin-cert"
    origin_key        = "/leave-agent/origin-key"
    postgres_password = "/leave-agent/postgres-password" # read by the deploy script, exported for `compose up`
  }
}

resource "aws_ssm_parameter" "secret" {
  for_each = local.secret_names

  name  = each.value
  type  = "SecureString"
  value = "UNSET — put the real value out-of-band; see secrets.tf"

  lifecycle {
    ignore_changes = [value]
  }
}
