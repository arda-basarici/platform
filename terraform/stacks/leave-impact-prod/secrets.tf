# Secrets ride SSM Parameter Store (SecureString, standard tier — free), the
# ruling over SOPS for the AWS side: the instance role reads by path, nothing
# lives on the workstation or in git, every read is a CloudTrail event.
#
# Terraform owns the parameters' existence and names; it never owns their
# values. Each is created with a placeholder through the write-only argument
# (`value_wo`), and the real content is put out-of-band (`aws ssm put-parameter
# --overwrite`). The hazard to keep in view: `value_wo_version` is the write
# trigger, so any change to it makes the next apply overwrite the real value with
# the placeholder — it stays at 1, and if it must move, the values are saved
# first and re-put right after. The proof that nothing enters state, and the
# history before it, are ARCHITECTURE's state map ("Secret values and state").
# The pair is a Cloudflare Origin CA certificate issued for this
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

  name             = each.value
  type             = "SecureString"
  value_wo         = "UNSET — put the real value out-of-band; see secrets.tf"
  value_wo_version = 1
}
