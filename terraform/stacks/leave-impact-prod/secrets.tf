# Secrets ride SSM Parameter Store (SecureString, standard tier — free), the
# ruling over SOPS for the AWS side: the instance role reads by path, nothing
# lives on the workstation or in git, every read is a CloudTrail event.
#
# Terraform owns the parameters' existence and names; it never owns their
# values. Each is created with a placeholder through the write-only argument
# (`value_wo`): the provider sends it once and never reads the value back, so
# the real content, put out-of-band from Arda's terminal (`aws ssm
# put-parameter --overwrite`), never enters the state file. Refresh sees only
# the parameter's version counter move. The one way an apply overwrites the
# real value is a change to `value_wo_version` — that is the signal to write
# again, so it stays at 1 unless the placeholder itself must be re-sent (and
# then the real values are re-put right after; proven 2026-08-27 on a scratch
# parameter, then on these three). Before that date the resources used `value`
# + `ignore_changes`, which kept the values out of *plans* but not out of state.
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
