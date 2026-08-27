# The remote-state bucket, adopted into the stack it serves (2026-08-28). It was
# the one hand-made resource (backend.tf), because a stack cannot store state in
# a bucket it has not created; adoption by import closes that gap without a
# second stack. The chicken-and-egg stays real: destroying this resource would
# destroy the stack's own state, hence prevent_destroy.
#
# Why a lifecycle rule: versioning keeps every past state file, and before the
# 2026-08-27 value_wo migration state held the origin certificate and key. The
# migration cleared the current version; noncurrent versions keep old content
# until they expire. 30 days is the rollback horizon for a corrupted write.
# The versions that held key material were purged by hand the day this landed.

resource "aws_s3_bucket" "tfstate" {
  bucket = "leave-impact-tfstate-445743457479"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-noncurrent-state"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    # The S3 lock file is created and deleted around every plan/apply; each
    # cycle leaves a delete marker behind. Expired markers are pure noise.
    expiration {
      expired_object_delete_marker = true
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
