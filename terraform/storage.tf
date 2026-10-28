# ------------------------------------------------------------------------------
# Amazon S3: Artefact and Log-Archive Bucket
# ------------------------------------------------------------------------------
# WHY THIS EXISTS: the audit brief asks for "storage services using AWS S3 or
# similar" (docs/readme.md:143) and the repository contained no storage service
# at all - `grep -nE 'aws_s3_bucket|aws_efs|aws_fsx' terraform/*.tf` returned
# nothing. Every service here was ECS-managed, so there was nothing to read from
# a filesystem either.
#
# WHAT WRITES TO IT: the internal ALB delivers its access logs here, under
# alb-access-logs/ (alb.tf, access_logs). One gzip file per ALB node every 5
# minutes, one line per request with the target IP:port that served it, so the
# per-target split of the traffic can be read from S3. They expire after
# var.log_retention_days, like the CloudWatch log groups.
#
# WHAT ELSE IT IS FOR: archive space for build and release artefacts (images
# from scripts/build_push.sh exported as tarballs) and for exports from the
# CloudWatch log groups before their retention ends. Nothing in this repository
# writes those yet; only the ALB does.
#
# Cost: S3 storage and PUT requests only; ELB does not charge for delivering the
# logs. At demo traffic that is cents per month. Set var.enable_artifact_bucket =
# false to skip the bucket for a throwaway sandbox; that also turns the ALB
# access logs off.
# ------------------------------------------------------------------------------

locals {
  # Key prefix for the ALB access logs. ELB appends AWSLogs/<account-id>/... to
  # it, and the prefix itself must not contain "AWSLogs".
  alb_access_log_prefix = "alb-access-logs"
}

resource "aws_s3_bucket" "artifacts" {
  count = var.enable_artifact_bucket ? 1 : 0

  # Global namespace, so the name has to be unique across all AWS accounts; the
  # account id makes a collision effectively impossible for this project name.
  bucket = "${local.name_prefix}-artifacts-${local.account_id}"

  # FIX for T15: the bucket now always holds objects (the ALB access logs, and
  # with versioning every older version too), and S3 refuses to delete a bucket
  # that is not empty, so `terraform destroy` would stop with BucketNotEmpty.
  # force_destroy makes Terraform delete every object version first. The ALB is
  # destroyed before the bucket (it depends on the bucket policy), so no new log
  # file arrives while the bucket is being emptied.
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-artifacts"
  })
}

# Encryption at rest. SSE-S3 (AES256) rather than aws:kms: it costs no key and
# therefore no key policy, no KMS grant and no extra per-request charge. It is
# also required: SSE-S3 is the only bucket encryption that ALB access log
# delivery supports, so switching this to aws:kms would stop the ALB logs.
# The bucket does NOT reuse
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

  # The ALB access logs expire much sooner, after the same number of days as the
  # CloudWatch log groups. Where two expiration rules cover the same object, S3
  # applies the shorter one, so these never reach the 90-day GLACIER transition
  # above (which for thousands of small log files would cost more in transition
  # requests than it saves). With versioning on, expiry only adds a delete
  # marker; the noncurrent version is then removed a day later.
  rule {
    id     = "alb-access-logs-expiry"
    status = "Enabled"

    filter {
      prefix = "${local.alb_access_log_prefix}/"
    }

    expiration {
      days = var.log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }
}

# Deny every request that is not over TLS, deny uploads that ask for anything
# but server-side encryption, and allow the ALB to deliver its access logs.
# Deny statements must use an explicit principal and cannot rely on
# NotPrincipal, so both are "*" and the effect is what blocks the request. The
# denies apply to the log delivery too, which is fine: it uses TLS and the
# bucket's default SSE-S3 encryption.
data "aws_iam_policy_document" "artifacts" {
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

    # FIX: this condition was missing, so the statement denied EVERY request
    # from every principal, TLS or not. Once applied, Terraform itself got
    # AccessDenied on the bucket, so the next plan and the destroy failed, and
    # only the account root user could delete the policy.
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
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

  # ALB access log delivery. The service principal is the policy AWS now
  # recommends in every Region (the per-Region ELB account IDs are the legacy
  # form). PutObject only, and only under this account's AWSLogs/ path below
  # the prefix. aws:SourceArn narrows it to load balancers of this account and
  # Region named like this project's ALB; the ARN has to be a pattern, because
  # naming aws_lb.main.arn here would be a cycle (the ALB waits for this policy
  # before it turns logging on).
  statement {
    sid    = "AllowAlbAccessLogDelivery"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }

    actions = ["s3:PutObject"]

    resources = ["${aws_s3_bucket.artifacts[0].arn}/${local.alb_access_log_prefix}/AWSLogs/${local.account_id}/*"]

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:elasticloadbalancing:${local.region}:${local.account_id}:loadbalancer/app/${local.name_prefix}-alb/*"]
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  count = var.enable_artifact_bucket ? 1 : 0

  bucket = aws_s3_bucket.artifacts[0].id
  policy = data.aws_iam_policy_document.artifacts[0].json

  # Depends on encryption being configured first, so the policy can never be the
  # reason an upload is refused.
  depends_on = [aws_s3_bucket_server_side_encryption_configuration.artifacts]
}