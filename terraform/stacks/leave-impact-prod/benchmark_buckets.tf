# --- The benchmark's two buckets ---------------------------------------------
# The leave agent is evaluated against a generated world whose answer key must be
# unreachable by the application by construction, not by promise (the ruling is
# the leave-impact-agent repository's DESIGN, "sealed is enforced, not
# promised"). Two buckets, not two prefixes, because a bucket is the unit IAM
# reasons about in one glance: "no statement on the instance role names the
# truth bucket" is checkable by reading benchmark_roles.tf.
#
#   world  — what the application may see. `worlds/<version>/…` holds the final
#            artifacts (manifest, scenario specs, the documents' canonical form,
#            the validator's verdicts); `preparing/` holds the generator's
#            restart checkpoint, overwritten freely and never served.
#   truth  — the answer key. `world-spec/` (read by the validator, at M2 the
#            evaluator) and `truth-manifest/` (the evaluator only). No
#            noncurrent-version expiry: history is provenance. `access-probe/`
#            holds the one platform-owned key (the read-denied canary, below).
#
# The container is platform, the content and the key layout are the
# application's (DESIGN, the ownership line). The prefixes are the contract,
# written once here and once in projects/leave-impact/README.md; a layout change
# edits both. The bucket shape copies the state bucket (state_bucket.tf).

locals {
  benchmark_buckets = {
    world = {
      # Final prefixes are create-only (the bucket policy below); the mutable
      # prefix is exempt and gets a short noncurrent-version expiry, since a
      # resumed generator reads only the current checkpoint and every projected
      # record overwrites it once.
      final_prefixes = ["worlds/"]
      mutable_prefix = "preparing/"
    }
    truth = {
      final_prefixes = ["world-spec/", "truth-manifest/"]
      mutable_prefix = null
    }
  }
}

resource "aws_s3_bucket" "benchmark" {
  for_each = local.benchmark_buckets
  bucket   = "leave-impact-${each.key}-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "benchmark" {
  for_each = aws_s3_bucket.benchmark
  bucket   = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "benchmark" {
  for_each                = aws_s3_bucket.benchmark
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "benchmark" {
  for_each = aws_s3_bucket.benchmark
  bucket   = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "benchmark" {
  for_each = aws_s3_bucket.benchmark
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "benchmark" {
  for_each = aws_s3_bucket.benchmark
  bucket   = each.value.id

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # One day is the minimum S3 accepts; lifecycle evaluates daily, so an
  # overwritten checkpoint lives up to about two days. Final prefixes keep every
  # version on both buckets.
  dynamic "rule" {
    for_each = local.benchmark_buckets[each.key].mutable_prefix == null ? [] : [local.benchmark_buckets[each.key].mutable_prefix]
    content {
      id     = "expire-overwritten-checkpoints"
      status = "Enabled"
      filter {
        prefix = rule.value
      }
      noncurrent_version_expiration {
        noncurrent_days = 1
      }
    }
  }
}

# Two denies, both on every principal (the account's administrators included):
# plain HTTP, and any object creation on a final prefix that does not carry
# `If-None-Match: *`. S3 evaluates that header against the current version
# only, so on these versioned buckets a key is written once and then refused
# with 412 — the application's create-only discipline, enforced server-side.
# Consequences the writer must know (docs, "Enforce conditional writes"):
# CopyObject into a final prefix fails (403 without the header, 501 with it),
# and multipart uploads fail at CreateMultipartUpload, which carries no
# conditional header — every final object is one PutObject, which is fine for
# artifacts measured in kilobytes. The mutable prefix is simply not listed.
# The condition key is probed live after apply (a conditional put twice → 412;
# a plain put → 403); the probe object is the only thing an administrator ever
# deletes here.
data "aws_iam_policy_document" "benchmark_bucket" {
  for_each = local.benchmark_buckets

  statement {
    sid       = "DenyPlainHttp"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.benchmark[each.key].arn, "${aws_s3_bucket.benchmark[each.key].arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyOverwriteOnFinalPrefixes"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = [for p in each.value.final_prefixes : "${aws_s3_bucket.benchmark[each.key].arn}/${p}*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Null"
      variable = "s3:if-none-match"
      values   = ["true"]
    }
  }
}

resource "aws_s3_bucket_policy" "benchmark" {
  for_each = aws_s3_bucket.benchmark
  bucket   = each.value.id
  policy   = data.aws_iam_policy_document.benchmark_bucket[each.key].json

  # A policy on a bucket with Block Public Access must be applied after the
  # block exists, or S3 rejects it as potentially public during the window.
  depends_on = [aws_s3_bucket_public_access_block.benchmark]
}

# A key known to exist in the truth bucket, for the read-denial probes. S3 hides
# existence: with ListBucket denied, a GET on an absent key returns AccessDenied
# whether or not GetObject is granted, so every probe against an invented key
# proves only the list denial. A GET on this key refused is the proof that
# GetObject is denied — the application's deploy step asserts it under the
# instance profile, the validator asserts it for itself. It sits outside the
# final prefixes because the provider sends no `If-None-Match` (the create-only
# deny would refuse the put); a canary under `truth-manifest/` is not possible
# from here, so that prefix's denial is proven against a real key once a world
# exists. Refresh reads it by HeadObject only.
resource "aws_s3_object" "truth_read_denied_canary" {
  bucket       = aws_s3_bucket.benchmark["truth"].id
  key          = "access-probe/read-denied-canary"
  content_type = "text/plain"
  content      = <<-EOT
    read-denied canary. This key exists so that a refused GET here proves the
    caller lacks GetObject on the truth bucket, not merely that the key is
    absent. Created by terraform/stacks/leave-impact-prod/benchmark_buckets.tf;
    nothing reads its content.
  EOT
}

output "benchmark_bucket_names" {
  description = "The world and truth buckets, by role (`world`, `truth`) — the application's literal config."
  value       = { for k, b in aws_s3_bucket.benchmark : k => b.bucket }
}
