# Secrets ride SSM Parameter Store (SecureString, standard tier — free), the
# ruling over SOPS for the AWS side: the instance role reads them by exact name
# (instance.tf renders this map into its read statement), nothing lives on the
# workstation or in git, every read is a CloudTrail event.
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
#
# The vendor entries are the investigator's read-only principals (the agent's
# M2-entry ruling, 2026-09-20): a third user per vendor, distinct from the
# generator's writing credentials (GitHub environment secrets, never here) and
# the validator's reading ones (the runner's), so a revocation names one
# consumer. The values are the application's, put at its vendor ceremony; until
# then the application reads the placeholder and must treat it as absent. The
# Jira e-mail is the one `String`: an account address is normal config, and
# DESIGN vaults only the secret class — it is still put out of band, so no
# address sits in this tree.
locals {
  parameters = {
    origin_cert                 = { name = "/leave-agent/origin-cert", type = "SecureString" }
    origin_key                  = { name = "/leave-agent/origin-key", type = "SecureString" }
    postgres_password           = { name = "/leave-agent/postgres-password", type = "SecureString" } # read by the deploy script, exported for `compose up`
    frappe_api_key              = { name = "/leave-agent/frappe-api-key", type = "SecureString" }
    frappe_api_secret           = { name = "/leave-agent/frappe-api-secret", type = "SecureString" }
    jira_token                  = { name = "/leave-agent/jira-token", type = "SecureString" }
    jira_email                  = { name = "/leave-agent/jira-email", type = "String" }
    google_authorized_user_json = { name = "/leave-agent/google-authorized-user-json", type = "SecureString" } # client id, client secret, refresh token: well inside the standard tier's 4 KB
  }
}

resource "aws_ssm_parameter" "secret" {
  for_each = local.parameters

  name             = each.value.name
  type             = each.value.type
  value_wo         = "UNSET — put the real value out-of-band; see secrets.tf"
  value_wo_version = 1
}
