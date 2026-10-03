# ------------------------------------------------------------------------------
# Amazon S3: Artefact and Log-Archive Bucket
# ------------------------------------------------------------------------------
# WHY THIS EXISTS: the audit brief asks for "storage services using AWS S3 or
# similar" (docs/readme.md:143) and the repository contained no storage service
# at all - `grep -nE 'aws_s3_bucket|aws_efs|aws_fsx' terraform/*.tf` returned
# nothing. Every service here was ECS-managed, so there was nothing to read from
# a filesystem either.
#
# WHAT IT IS FOR, precisely: durable, cheap, long-retention storage for build and
# release artefacts (the images built by scripts/build_push.sh, exported as
# tarballs) and for log/trace exports pulled out of the CloudWatch log groups in
# cloudwatch.tf before their retention window expires.
#
# WHAT IT IS NOT FOR, stated plainly so this is not mistaken for an integrated
# feature: NOTHING IN THE APPLICATION WRITES TO IT YET. No ECS task, no lambda
# and no script in this repository references the bucket ARN. It is deliberately
# configured, empty and ready - and versioned, so that once something does write,
# the version history is there from the start. An empty, versioned, encrypted
# bucket in this account costs nothing beyond the requests made against it, which
# is why it is on by default; set var.enable_artifact_bucket = false to skip it
# for a throwaway sandbox.
# ------------------------------------------------------------------------------

resource "aws_s3_bucket" "artifacts" {
  count = var.enable_artifact_bucket ? 1 : 0

  # Global namespace, so the name has to be unique across all AWS accounts; the
  # account id makes a collision effectively impossible for this project name.
  bucket = "${local.name_prefix}-artifacts-${local.account_id}"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-artifacts"
  })
}

# Encryption at rest. SSE-S3 (AES256) rather than aws:kms: it costs no key and
# therefore no key policy, no KMS grant and no extra per-request charge, which
# matters for a bucket nothing writes to yet. The bucket does NOT reuse
# aws_kms_key.rds - that key is named for RDS storage and the audit trail should
# not imply the artefacts share the database's blast radius. Revisit if anything
# ever writes regulated data here.
resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  count = var.enable_artifact_bucket ? 1 : 0

  bucket = aws_s3_bucket.artifacts[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning on, because the point of an archive is that an overwrite is
# recoverable. It also means deleting a "current" object only adds a delete
# marker - the lifecycle rule below is what actually reclaims the bytes.
resource "aws_s3_bucket_versioning" "artifacts" {
  count = var.enable_artifact_bucket ? 1 : 0

  bucket = aws_s3_bucket.artifacts[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

# No ACLs at all. Object ownership stays with the bucket owner, so any future
# PutObjectAcl is rejected rather than quietly reintroducing a second authority.
resource "aws_s3_bucket_ownership_controls" "artifacts" {
  count = var.enable_artifact_bucket ? 1 : 0

  bucket = aws_s3_bucket.artifacts[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Belt and braces with the SG model: even if a future resource attaches a public
# ACL or a policy mistake opens something up, all four flags forbid it at the
# bucket level.
resource "aws_s3_bucket_public_access_block" "artifacts" {
  count = var.enable_artifact_bucket ? 1 : 0

  bucket = aws_s3_bucket.artifacts[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Cost control. An archive that never ages out is an unbounded bill, so:
#   - non-current versions are dropped after 30 days (they only exist because
#     versioning is on, and only the live version is needed to restore);
#   - current versions move to GLACIER after 90 days (roughly a third of S3
#     Standard's storage price, at the cost of minutes-long restores);
#   - current versions are deleted after 365 days.
# `filter {}` is an empty filter, which the provider documents as "applies to all
# objects in the bucket" - the newer replacement for the deprecated `prefix` arg.
resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  count = var.enable_artifact_bucket ? 1 : 0

  # Versioning must exist before the lifecycle rule references non-current versions.
  depends_on = [aws_s3_bucket_versioning.artifacts]

  bucket = aws_s3_bucket.artifacts[0].id

  rule {
    id     = "archive-tiering"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }
}

# Deny every request that is not over TLS, and deny the deprecated
# unencrypted-S3 API calls outright. Deny statements must use an explicit
# principal and cannot rely on NotPrincipal, so both are "*" and the effect is
# what blocks the request.
data "aws_iam_policy_document" "artifacts_tls_only" {
  # The SAME count guard as the bucket. This is not decoration: a data source is
  # read during plan whenever its configuration can be evaluated, so with the
  # bucket at count = 0 an unguarded `aws_s3_bucket.artifacts[0].arn` here would
  # fail the whole run with "Invalid index" - the data block does not care that
  # the only resource referencing it also has count = 0.
  count = var.enable_artifact_bucket ? 1 : 0

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.artifacts[0].arn,
      "${aws_s3_bucket.artifacts[0].arn}/*",
    ]
  }

  # Deny an upload that explicitly asks for something other than server-side
  # encryption. The `Null ... = "false"` clause is load-bearing: without it,
  # StringNotEquals also matches an ABSENT header, which would reject every
  # upload that relies on the bucket's default encryption above and never sets
  # the header itself. With it, the deny fires only when a caller sends a value
  # that is neither aws:kms nor AES256.
  statement {
    sid    = "DenyUnencryptedObjectUploads"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:PutObject",
      "s3:PutObjectAcl",
    ]

    resources = ["${aws_s3_bucket.artifacts[0].arn}/*"]

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms", "AES256"]
    }

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  count = var.enable_artifact_bucket ? 1 : 0

  bucket = aws_s3_bucket.artifacts[0].id
  policy = data.aws_iam_policy_document.artifacts_tls_only[0].json

  # Depends on encryption being configured first, so the policy can never be the
  # reason an upload is refused.
  depends_on = [aws_s3_bucket_server_side_encryption_configuration.artifacts]
}