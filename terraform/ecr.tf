# ------------------------------------------------------------------------------
# Amazon ECR: Container Image Registry Backing the ECS Fargate Services
# ------------------------------------------------------------------------------
# ECS tasks pull `image` from an ECR repository URL. Without these repositories
# nothing can be pushed and every task definition fails to stabilise, so this
# file is a hard prerequisite of ecs_services.tf.
#
# Push workflow: `PUSH=1 bash scripts/build_push.sh` pushes every application
# image as :latest and as the git short SHA; the task definitions pull
# var.image_tag (default "latest", see local.ecr_image_urls in ecs_services.tf).
# By hand, for one image:
#   REG=$(terraform output -raw ecr_registry_url)
#   aws ecr get-login-password --region us-east-1 \
#     | docker login --username AWS --password-stdin "$REG"
#   docker build -f srcs/api-gateway/Dockerfile srcs/api-gateway \
#     -t "$REG/cloud-design/api-gateway:latest"
#   docker push "$REG/cloud-design/api-gateway:latest"
# MUTABLE below is what lets :latest move to each new build. A SHA tag only
# moves if the same commit is pushed again, and then to a rebuild of the same
# sources.
# The Dockerfile is at srcs/<component>/Dockerfile and the build context is that
# same directory (so srcs/<component>/.dockerignore applies) - the previous
# revision of this comment pointed at Dockerfiles/Dockerfile.api-gateway, a path
# that does not exist anywhere in the repo. Note also that the on-disk component
# directory is `api-gateway` while the repository/image name is
# `cloud-design/api-gateway` (local.app_images below), so the -t tag and the
# directory name are deliberately not the same string.
# ------------------------------------------------------------------------------

locals {
  # Images actually deployed to ECS Fargate. The two PostgreSQL databases and the
  # RabbitMQ broker run as *managed* AWS services (RDS Multi-AZ / Amazon MQ), so
  # their Dockerfiles are deliberately NOT registered here: an ECR repository
  # with no ECS service behind it would be dead infrastructure and would cost
  # nothing but reviewer confusion.
  app_images = {
    api-gateway   = "cloud-design/api-gateway"
    inventory-app = "cloud-design/inventory-app"
    billing-app   = "cloud-design/billing-app"
  }
}

resource "aws_ecr_repository" "app" {
  for_each = local.app_images

  name                 = each.value
  image_tag_mutability = "MUTABLE"
  # `terraform destroy` must not fail on repositories that still hold images.
  force_delete = true

  # Scan every pushed image (scan_on_push). COST CORRECTION: the previous
  # revision of this comment claimed "no extra charge". That is true of ECR
  # BASIC scanning only. Once aws_inspector2_enabler (inspector2.tf) is enabled
  # for ECR, these scans are performed by Inspector's ENHANCED scanning and are
  # billed per scan - roughly $0.09 per initial scan and $0.01 per re-scan in
  # us-east-1, and every new CVE in the Inspector database triggers re-scans of
  # the retained images. For three repositories with a 5-image lifecycle policy
  # that is cents per month, not dollars, so it is still enabled - but it is not
  # free and the budget estimate (var.monthly_budget_limit) includes it.
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ecr-${replace(each.value, "/", "-")}"
  })
}

# Repository policy: allow the owning account (i.e. the ECS task execution role
# and the developer running `docker push`) to pull and enumerate images. ECR
# already denies cross-account access by default, so this only makes the
# account-local grant explicit and auditable.
data "aws_iam_policy_document" "ecr_repository" {
  for_each = local.app_images

  statement {
    sid    = "AccountLocalImageAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }

    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
    ]
  }
}

resource "aws_ecr_repository_policy" "app" {
  for_each = local.app_images

  repository = aws_ecr_repository.app[each.key].name
  policy     = data.aws_iam_policy_document.ecr_repository[each.key].json
}

# Retention: keep only the 5 most recent images per repository so that repeated
# CI pushes cannot grow ECR storage without bound.
data "aws_ecr_lifecycle_policy_document" "app" {
  for_each = local.app_images

  rule {
    priority    = 1
    description = "Expire images beyond the 5 most recent pushes"

    selection {
      tag_status   = "any"
      count_type   = "imageCountMoreThan"
      count_number = 5
    }

    action {
      type = "expire"
    }
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each = local.app_images

  repository = aws_ecr_repository.app[each.key].name
  policy     = data.aws_ecr_lifecycle_policy_document.app[each.key].json
}
