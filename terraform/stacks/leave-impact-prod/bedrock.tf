# --- Bedrock: which models code on the instance may call ---------------------
# Pinned to the shortlist, not `*` (ruled 2026-08-26): an inference-profile
# invocation needs the profile itself AND every foundation model it routes to
# (the `eu.` profiles fan out across EU regions), so the data source resolves
# both from the ID list — `bedrock_models` in `variables.tf` is the only thing to
# edit when the agent's model measurements (a milestone its repository's DESIGN
# names) settle the choice.
data "aws_bedrock_inference_profile" "shortlist" {
  for_each             = toset(var.bedrock_models)
  inference_profile_id = each.value
}

locals {
  bedrock_invocable_arns = concat(
    [for p in data.aws_bedrock_inference_profile.shortlist : p.inference_profile_arn],
    flatten([for p in data.aws_bedrock_inference_profile.shortlist : [for m in p.models : m.model_arn]]),
  )
}

data "aws_iam_policy_document" "instance_bedrock" {
  statement {
    sid       = "InvokeShortlistedModels"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = local.bedrock_invocable_arns
  }
}

resource "aws_iam_role_policy" "instance_bedrock" {
  name   = "invoke-shortlisted-models"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance_bedrock.json
}
