# Continuous deployment without stored keys: GitHub Actions federates into this
# account through OIDC (DESIGN, "The surrounding AWS set"). A workflow job
# presents a short-lived GitHub-signed token; STS exchanges it for temporary
# credentials only when the token's subject names this repository's
# `production` environment. Nothing to rotate, nothing to leak.

# One provider per account (GitHub's issuer is global). The thumbprints are
# GitHub's published root CA fingerprints; AWS validates GitHub's issuer through
# its own trust store since 2023 and treats these as informational.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

# Trust: the subject a job emits when it runs under an environment. Recorded
# from the first run (oidc-deploy probe, 2026-08-26): repositories created
# after mid-2026 carry the owner's and the repository's numeric ids in the
# subject — `repo:<owner>@<id>/<repo>@<id>:environment:<name>` — which is the
# stronger pin (a renamed or re-created repository of the same name inherits
# nothing). The classic name-only form was the documented one and was
# rejected by STS. The branch pin lives in the environment's deployment-branch
# policy on GitHub (main only) alongside the required-reviewer gate.
data "aws_iam_policy_document" "deploy_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:arda-basarici@133336041/leave-impact-agent@1342572683:environment:production"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name               = "leave-agent-deploy"
  assume_role_policy = data.aws_iam_policy_document.deploy_assume.json
}

# Permissions: find the app host by tag and run one document on it. The
# instance is addressed by its Name tag, not its id, so a replaced instance is
# deployable without a workflow edit; the tag condition keeps the role from
# reaching any other instance the account may hold later.
data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "FindTheAppHost"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
  statement {
    sid       = "RunTheDeployScript"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:eu-central-1::document/AWS-RunShellScript"]
  }
  statement {
    sid       = "OnTheAppHostOnly"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:eu-central-1:${data.aws_caller_identity.current.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Name"
      values   = ["leave-agent-app"]
    }
  }
  statement {
    sid       = "ReadTheOutcome"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy-to-app-host"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

output "deploy_role_arn" {
  description = "What the workflow's deploy job assumes (`role-to-assume`)."
  value       = aws_iam_role.deploy.arn
}
