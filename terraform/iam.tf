# ------------------------------------------------------------------------------
# IAM Roles & Policies for ECS Fargate and API Gateway
# ------------------------------------------------------------------------------
# The EKS cluster/node IAM roles that lived here were removed with the EKS path
# (see orchestration.tf). Everything below is used by the ECS services or by API
# Gateway's CloudWatch integration.
# ------------------------------------------------------------------------------

# 1. ECS Task Execution Role (Pulling images, writing logs, retrieving secrets)
resource "aws_iam_role" "ecs_task_execution" {
  name = "${local.name_prefix}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  role       = aws_iam_role.ecs_task_execution.name
}

# Explicit, repository-scoped ECR pull permissions.
# AmazonECSTaskExecutionRolePolicy already grants these on "*"; narrowing them to
# this project's repositories means a compromised task can only read images that
# belong to this stack rather than every repository in the account.
resource "aws_iam_policy" "ecs_ecr_pull" {
  name        = "${local.name_prefix}-ecs-ecr-pull"
  description = "Allows ECS tasks to pull container images from the project ECR repositories only"

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
        ]
        Resource = [for repo in aws_ecr_repository.app : repo.arn]
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_ecr_pull_attachment" {
  policy_arn = aws_iam_policy.ecs_ecr_pull.arn
  role       = aws_iam_role.ecs_task_execution.name
}

# Custom policy for ECS task execution to read secrets from AWS Secrets Manager
# Scoped to project secrets + RDS KMS key (no wildcard secrets/kms access).
resource "aws_iam_policy" "ecs_secrets_access" {
  name        = "${local.name_prefix}-ecs-secrets-access"
  description = "Allows ECS tasks to read database and MQ credentials from Secrets Manager"

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          aws_secretsmanager_secret.inventory_db.arn,
          aws_secretsmanager_secret.billing_db.arn,
          aws_secretsmanager_secret.mq_credentials.arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [aws_kms_key.rds.arn]
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_secrets_access_attachment" {
  policy_arn = aws_iam_policy.ecs_secrets_access.arn
  role       = aws_iam_role.ecs_task_execution.name
}

# 2. ECS Task Role (Runtime permissions for running microservice containers)
resource "aws_iam_role" "ecs_task" {
  name = "${local.name_prefix}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_policy" "ecs_task_cloudwatch_policy" {
  name        = "${local.name_prefix}-ecs-task-cloudwatch"
  description = "Allows containers to emit custom CloudWatch metrics and traces"

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        # cloudwatch:PutMetricData and X-Ray APIs do not support
        # resource-level permissions; "*" is required by AWS here.
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "${aws_cloudwatch_log_group.api_gateway_app.arn}:*",
          "${aws_cloudwatch_log_group.inventory_app.arn}:*",
          "${aws_cloudwatch_log_group.billing_app.arn}:*"
        ]
      },
      {
        # Required by `enable_execute_command = true` on the ECS services
        # (aws ecs execute-command, used to demo a live task at audit).
        # Without these the flag silently does nothing useful.
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "*"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_cloudwatch_attachment" {
  policy_arn = aws_iam_policy.ecs_task_cloudwatch_policy.arn
  role       = aws_iam_role.ecs_task.name
}

# 3. API Gateway CloudWatch Logging Account Role
resource "aws_iam_role" "api_gateway_cloudwatch" {
  name = "${local.name_prefix}-apigw-cloudwatch-role"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "apigateway.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "api_gateway_cloudwatch_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
  role       = aws_iam_role.api_gateway_cloudwatch.name
}

# Account-wide setting that lets API Gateway write stage access logs to
# CloudWatch with the role above. This is an account-level singleton and must
# exist before any stage that sets access_log_settings can deploy.
resource "aws_api_gateway_account" "cloudwatch_account" {
  cloudwatch_role_arn = aws_iam_role.api_gateway_cloudwatch.arn
}
