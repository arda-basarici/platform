# --- Who may touch the benchmark buckets, and with what ----------------------
# Three readers with three different rights, and the application with almost
# none. The privileged jobs (the generator writes the world and its truth; the
# validator re-reads the live systems against the sealed spec and writes a
# verdict) run as GitHub Actions workflows under the agent repository's
# `benchmark` environment, each run approved by that environment's reviewer, and
# assume a role here through the same OIDC trust as the deploy job (deploy.tf).
# Nothing on the instance can assume either role: the instance role carries no
# `sts:AssumeRole` at all, and that absence is the boundary (ruled 2026-09-12 in
# the agent's DESIGN, superseding "the generator runs from the instance"). A role
# the instance could assume would be a role the application could obtain, and an
# access-denied probe would then prove only direct access.
#
# One environment for both roles, deliberately: `benchmark` is the single
# privileged operator plane, separate from `production` so the deploy job cannot
# write truth. The generator/validator split lives in these two policies, not in
# a second environment. The evaluator (reads the truth manifest, M2) is absent
# until its execution boundary is known.

data "aws_iam_policy_document" "benchmark_assume" {
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
      values   = ["repo:${local.github_repository}:environment:benchmark"]
    }
  }
}

locals {
  world_bucket_arn = aws_s3_bucket.benchmark["world"].arn
  truth_bucket_arn = aws_s3_bucket.benchmark["truth"].arn
}

# --- The generator ------------------------------------------------------------
# Writes everything once: the truth (spec and truth manifest), the world's final
# artifacts, and its own restart checkpoint under the mutable prefix. Create-only
# on the final prefixes is the bucket policy's job, so the grants here are plain
# puts. No delete anywhere: history is provenance, and a mistaken write is
# superseded by a new version, never removed. Get-by-version lets a writer read
# back exactly the version id it recorded.
data "aws_iam_policy_document" "generator" {
  statement {
    sid       = "ListTheWorldBucket"
    actions   = ["s3:ListBucket"]
    resources = [local.world_bucket_arn]
  }
  statement {
    sid       = "ReadAndWriteWorldArtifacts"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
    resources = ["${local.world_bucket_arn}/worlds/*", "${local.world_bucket_arn}/preparing/*"]
  }
  statement {
    sid       = "WriteTheTruth"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
    resources = ["${local.truth_bucket_arn}/world-spec/*", "${local.truth_bucket_arn}/truth-manifest/*"]
  }
  statement {
    sid       = "InvokeGeneratorModels"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = local.bedrock_generator_invocable_arns
  }
}

resource "aws_iam_role" "generator" {
  name                 = "leave-agent-generator"
  assume_role_policy   = data.aws_iam_policy_document.benchmark_assume.json
  max_session_duration = 7200 # a web-identity session is not role chaining, so the one-hour chaining cap does not apply; a world takes longer than an hour to project
}

resource "aws_iam_role_policy" "generator" {
  name   = "write-world-and-truth"
  role   = aws_iam_role.generator.id
  policy = data.aws_iam_policy_document.generator.json
}

# --- The validator ------------------------------------------------------------
# Reads the world's artifacts and the sealed spec, re-reads the live vendor
# systems over the public edge (not an AWS matter), and writes one verdict per
# run under `worlds/<version>/verdicts/`. It learns the spec's key from the
# manifest, so it needs no list on the truth bucket. It calls no model.
data "aws_iam_policy_document" "validator" {
  statement {
    sid       = "ListTheWorlds"
    actions   = ["s3:ListBucket"]
    resources = [local.world_bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["worlds/", "worlds/*"]
    }
  }
  statement {
    sid       = "ReadWorldArtifacts"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${local.world_bucket_arn}/worlds/*"]
  }
  statement {
    sid       = "WriteVerdicts"
    actions   = ["s3:PutObject"]
    resources = ["${local.world_bucket_arn}/worlds/*/verdicts/*"]
  }
  statement {
    sid       = "ReadTheSealedSpec"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${local.truth_bucket_arn}/world-spec/*"]
  }
}

resource "aws_iam_role" "validator" {
  name                 = "leave-agent-validator"
  assume_role_policy   = data.aws_iam_policy_document.benchmark_assume.json
  max_session_duration = 7200
}

resource "aws_iam_role_policy" "validator" {
  name   = "validate-worlds"
  role   = aws_iam_role.validator.id
  policy = data.aws_iam_policy_document.validator.json
}

# --- The application's view -----------------------------------------------------
# The instance role (instance.tf) gains exactly this: list and read under
# `worlds/`. Nothing under `preparing/`, no statement naming the truth bucket,
# and no assume-role grant. The application's deploy step asserts the negative
# side live (a list on the truth bucket and a get on a truth key both refused),
# under the real instance profile — the evidence is the application's, the
# boundary is this file's.
data "aws_iam_policy_document" "instance_worlds" {
  statement {
    sid       = "ListTheWorlds"
    actions   = ["s3:ListBucket"]
    resources = [local.world_bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["worlds/", "worlds/*"]
    }
  }
  statement {
    sid       = "ReadWorldArtifacts"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${local.world_bucket_arn}/worlds/*"]
  }
}

resource "aws_iam_role_policy" "instance_worlds" {
  name   = "read-approved-worlds"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance_worlds.json
}

output "generator_role_arn" {
  description = "What the agent repository's generator workflow assumes (`role-to-assume`), under the `benchmark` environment."
  value       = aws_iam_role.generator.arn
}

output "validator_role_arn" {
  description = "What the agent repository's validator workflow assumes (`role-to-assume`), under the `benchmark` environment."
  value       = aws_iam_role.validator.arn
}
