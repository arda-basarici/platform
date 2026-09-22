# --- Who may touch the benchmark buckets, and with what ----------------------
# Three job roles with three different rights, and the application with almost
# none. The privileged jobs (the generator writes the world and its truth; the
# validator re-reads the live systems against the sealed spec and writes a
# verdict; the evaluator grades a run's export against the answer key and writes
# an evaluation) run as GitHub Actions workflows under the agent repository's
# environments, each run approved by its environment's reviewer, and assume a
# role here through the same OIDC trust as the deploy job (deploy.tf). Nothing
# on the instance can assume any of them: the instance role carries no
# `sts:AssumeRole` at all, and that absence is the boundary (ruled 2026-09-12 in
# the agent's DESIGN, superseding "the generator runs from the instance"). A role
# the instance could assume would be a role the application could obtain, and an
# access-denied probe would then prove only direct access.
#
# Two environments, deliberately. `benchmark` is the privileged operator plane
# for the generator and the validator, separate from `production` so the deploy
# job cannot write truth; their split lives in the two policies, not in a third
# environment. `evaluation` holds the evaluator alone and holds no secrets: the
# evaluator never touches a vendor or a model, and an environment with nothing
# to give is what keeps a vendor credential out of its job even if a workflow
# later references one (ruled at the agent's M2 entry, 2026-09-20). Every trust
# here binds an environment claim only; binding each role to its workflow file
# as well (`job_workflow_ref`) is a later hardening, landed on all three at once.

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

data "aws_iam_policy_document" "evaluation_assume" {
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
      values   = ["repo:${local.github_repository}:environment:evaluation"]
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

# --- The evaluator ------------------------------------------------------------
# Reads a finished run's export (`runs/`, written by the application, outside the
# `worlds/` tree it serves from) and the sealed truth, and writes one evaluation
# per execution under the truth bucket's `evaluations/`: an evaluation names
# which claims matched the key, so it carries the key's protection and lives
# beside it. No vendor, no model, no SSM: the difference from the validator is
# that the evaluator never re-reads a live system. No get on what it wrote — the
# put's response carries the version id it records. `audit/` stays outside its
# reach (DESIGN's ruling, unchanged at M2).
data "aws_iam_policy_document" "evaluator" {
  statement {
    sid       = "ListTheRunExports"
    actions   = ["s3:ListBucket"]
    resources = [local.world_bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["runs/", "runs/*"]
    }
  }
  statement {
    sid       = "ReadRunExports"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${local.world_bucket_arn}/runs/*"]
  }
  statement {
    sid       = "ReadTheTruth"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${local.truth_bucket_arn}/world-spec/*", "${local.truth_bucket_arn}/truth-manifest/*"]
  }
  statement {
    sid       = "WriteEvaluations"
    actions   = ["s3:PutObject"]
    resources = ["${local.truth_bucket_arn}/evaluations/*"]
  }
}

resource "aws_iam_role" "evaluator" {
  name                 = "leave-agent-evaluator"
  assume_role_policy   = data.aws_iam_policy_document.evaluation_assume.json
  max_session_duration = 7200
}

resource "aws_iam_role_policy" "evaluator" {
  name   = "evaluate-runs"
  role   = aws_iam_role.evaluator.id
  policy = data.aws_iam_policy_document.evaluator.json
}

# --- The application's view -----------------------------------------------------
# The instance role (instance.tf) gains exactly this: list and read under
# `worlds/`, and a put under `runs/` for the export of a finished run — create-
# only through the bucket policy, with no get and no list there, so the
# application hands its run to the evaluator and cannot read it back or see its
# siblings. Nothing under `preparing/`, no statement naming the truth bucket, and
# no assume-role grant. The application's deploy step asserts the negative side
# live (a list on the truth bucket and a get on a truth key both refused), under
# the real instance profile — the evidence is the application's, the boundary is
# this file's.
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
  statement {
    sid       = "WriteRunExports"
    actions   = ["s3:PutObject"]
    resources = ["${local.world_bucket_arn}/runs/*"]
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

output "evaluator_role_arn" {
  description = "What the agent repository's evaluator workflow assumes (`role-to-assume`), under the `evaluation` environment."
  value       = aws_iam_role.evaluator.arn
}
