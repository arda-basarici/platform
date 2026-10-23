# --- The app host's backup bucket -------------------------------------------
# The nightly pg_dump of the application's PostgreSQL lands here (the script is
# projects/leave-impact/backup.sh; the obligation is the leave-impact-agent
# repository's DESIGN: self-managed PostgreSQL carries a nightly off-host backup
# and one demonstrated restore). Its own bucket, not a prefix: the world and
# truth buckets hold the benchmark, whose key layout is the application's, and
# the state bucket holds Terraform's; a backup is platform-owned data with a
# platform-owned layout, so it gets a container IAM reasons about alone.
#
# Two prefixes, `daily/` and `weekly/`, both create-only (the bucket policy
# below, the benchmark buckets' pattern): an object is written once with
# `If-None-Match: *` and refused with 412 after, for every principal. The
# instance may put and get here and nothing else — no list, no delete — so a
# host-level attacker can read what the host already holds and can destroy
# nothing (the ruling of 2026-10-23, amended from "cannot read or delete": the
# read adds nothing against a host that holds the live database, and the
# monthly restore check on that host needs it). Pruning is the lifecycle's:
# seven dailies and four weeklies, the retention the box's backup keeps. Real
# recovery reads with an administrator identity from a workstation.
#
# The shape copies the benchmark buckets, resource for resource; a fourth
# bucket in this shape is the point to fold them into one definition.

resource "aws_s3_bucket" "backup" {
  bucket = "leave-impact-backup-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket                  = aws_s3_bucket.backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Retention by age, per prefix. On a versioned bucket an expiration leaves a
# delete marker over a noncurrent version, so each rule also expires that
# version a day later and a bucket-wide rule clears the markers once nothing
# is under them; an object is gone about two days after its retention ends.
resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    id     = "keep-seven-dailies"
    status = "Enabled"
    filter {
      prefix = "daily/"
    }
    expiration {
      days = 7
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  rule {
    id     = "keep-four-weeklies"
    status = "Enabled"
    filter {
      prefix = "weekly/"
    }
    expiration {
      days = 28
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  rule {
    id     = "clear-markers-and-aborted-uploads"
    status = "Enabled"
    filter {}
    expiration {
      expired_object_delete_marker = true
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# The benchmark buckets' two denies, on every principal: plain HTTP, and any
# object creation without `If-None-Match: *`. Every key here is final, so the
# second deny covers the whole bucket. The same consequences: no server-side
# copy in, no multipart upload in (a dump of some megabytes is one PutObject).
data "aws_iam_policy_document" "backup_bucket" {
  statement {
    sid       = "DenyPlainHttp"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.backup.arn, "${aws_s3_bucket.backup.arn}/*"]
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
    sid       = "DenyOverwrite"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.backup.arn}/*"]
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

resource "aws_s3_bucket_policy" "backup" {
  bucket = aws_s3_bucket.backup.id
  policy = data.aws_iam_policy_document.backup_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.backup]
}

# The instance's view: put and get on the objects, nothing on the bucket (no
# list), no delete. The put is create-only through the bucket policy; the get
# is the monthly restore check's, which fetches last night's key by name.
data "aws_iam_policy_document" "instance_backup" {
  statement {
    sid       = "WriteAndReadBackups"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.backup.arn}/*"]
  }
}

resource "aws_iam_role_policy" "instance_backup" {
  name   = "backup-store"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance_backup.json
}

output "backup_bucket_name" {
  description = "The app host's backup bucket — the backup units' config (cloud-init renders it into their environment file)."
  value       = aws_s3_bucket.backup.bucket
}
