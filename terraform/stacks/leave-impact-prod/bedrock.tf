# --- Bedrock: which models which role may call --------------------------------
# Pinned to a list, not `*` (ruled 2026-08-26): an inference-profile invocation
# needs the profile itself AND every foundation model it routes to (the `eu.`
# profiles fan out across EU regions), so the data source resolves both from the
# ID list. Two lists since 2026-09-12, one per caller: the agent's shortlist on
# the instance role, the generator's pair on the generator role
# (benchmark_roles.tf). Both live in `variables.tf`, the only place to edit when
# a model choice changes.

data "aws_bedrock_inference_profile" "agent" {
  for_each             = toset(var.bedrock_agent_models)
  inference_profile_id = each.value
}

data "aws_bedrock_inference_profile" "generator" {
  for_each             = toset(var.bedrock_generator_models)
  inference_profile_id = each.value
}

locals {
  bedrock_agent_invocable_arns = concat(
    [for p in data.aws_bedrock_inference_profile.agent : p.inference_profile_arn],
    flatten([for p in data.aws_bedrock_inference_profile.agent : [for m in p.models : m.model_arn]]),
  )
  bedrock_generator_invocable_arns = concat(
    [for p in data.aws_bedrock_inference_profile.generator : p.inference_profile_arn],
    flatten([for p in data.aws_bedrock_inference_profile.generator : [for m in p.models : m.model_arn]]),
  )
}

data "aws_iam_policy_document" "instance_bedrock" {
  statement {
    sid       = "InvokeShortlistedModels"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = local.bedrock_agent_invocable_arns
  }
}

resource "aws_iam_role_policy" "instance_bedrock" {
  name   = "invoke-shortlisted-models"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance_bedrock.json
}
