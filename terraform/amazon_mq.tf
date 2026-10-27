# ------------------------------------------------------------------------------
# Managed RabbitMQ Broker: Amazon MQ (Private Subnet)
# ------------------------------------------------------------------------------

# Broker credential.
# FIX: `override_special` used to contain "=" and ":", which Amazon MQ rejects.
# CreateBroker documents the password as "must not contain commas, colons, or
# equal signs (,:=)" and CloudFormation encodes that as Pattern ^[^,:=]+$ for
# AWS::AmazonMQ::Broker User.Password. random_password draws uniformly from the
# combined alphabet with no floor on specials, so roughly 45% of generated values
# contained a ":" or "=" and the broker simply refused to be created - and because
# the result lives in Terraform state, every retry reproduced the SAME bad
# password. Both characters are dropped below.
# min_special = 1 so the generated password always exercises the special-character
# path instead of relying on the 56% of draws that happen to avoid it; all 18
# characters left in the alphabet satisfy CreateBroker.
resource "random_password" "mq_admin" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_+[]{}<>?"
  min_special      = 1
}

locals {
  # Amazon MQ reports the broker as a full URL, e.g.
  #   "amqps://b-c8352341.mq.us-east-1.amazonaws.com:5671"
  # but pika's ConnectionParameters takes host and port as SEPARATE fields and
  # will not resolve a value that still carries a scheme. Split it here instead
  # of doing string surgery inside the container.
  # try() guards the plan-time window where the broker has not been created yet
  # and `instances` is still unknown/empty (same guard as the secret below).
  mq_amqps_endpoint = try(aws_mq_broker.rabbitmq.instances[0].endpoints[0], "")
  mq_amqps_host     = try(split(":", split("://", local.mq_amqps_endpoint)[1])[0], "")
}

resource "aws_secretsmanager_secret" "mq_credentials" {
  name = "${local.name_prefix}-amazon-mq-credentials"
  # FIX: this secret was the only one of the three with no CMK, so the broker
  # admin password sat under the AWS-managed aws/secretsmanager key while the
  # documentation claimed every credential was encrypted with the project's own
  # key. It is now encrypted with the same key as the two RDS secrets.
  # THE ORDERING TRAP THIS ALSO REMOVES: attaching a CMK to a secret that ECS
  # tasks already read requires the task EXECUTION role to hold kms:Decrypt on
  # that key. iam.tf already grants it (aws_iam_policy.ecs_secrets_access,
  # aws_kms_key.rds), so the secret rotates in place. Adding kms_key_id later
  # without that grant would make every task fail to launch on the next deploy
  # with an opaque ResourceInitializationError and no Terraform-side signal.
  kms_key_id              = aws_kms_key.rds.arn
  recovery_window_in_days = 0

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "mq_credentials" {
  secret_id = aws_secretsmanager_secret.mq_credentials.id
  secret_string = jsonencode({
    engine   = "rabbitmq"
    username = var.mq_user
    password = random_password.mq_admin.result
    endpoint = try(aws_mq_broker.rabbitmq.instances[0].endpoints[0], "")
  })
}

resource "aws_mq_broker" "rabbitmq" {
  broker_name        = "${local.name_prefix}-rabbitmq"
  engine_type        = "RabbitMQ"
  engine_version     = var.mq_engine_version
  host_instance_type = var.mq_host_instance_type
  # FIX: this was ACTIVE_STANDBY_MULTI_AZ, which is an ActiveMQ-only mode.
  # Amazon MQ for RabbitMQ offers exactly two modes, SINGLE_INSTANCE and
  # CLUSTER_MULTI_AZ (three broker nodes), so CreateBroker rejected the broker.
  # SINGLE_INSTANCE is the cost choice: a cluster triples the broker bill, and
  # the broker is the largest line in the estimate (var.monthly_budget_limit).
  # THE TRADE-OFF, stated plainly: the broker lives in one AZ and is briefly
  # offline during its weekly maintenance window. While it is down,
  # POST /api/billing answers 503 and the client has to retry; orders already
  # queued are durable, persistent messages (queue_sender.py) and are consumed
  # once the broker is back. CLUSTER_MULTI_AZ is the upgrade path.
  deployment_mode = "SINGLE_INSTANCE"

  # A single-instance broker takes exactly one subnet: the first private DB subnet.
  subnet_ids          = [aws_subnet.private_db[0].id]
  security_groups     = [aws_security_group.mq.id]
  publicly_accessible = false

  auto_minor_version_upgrade = true

  user {
    username = var.mq_user
    password = random_password.mq_admin.result
  }

  logs {
    general = true
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rabbitmq-broker"
    Tier = "Private-MQ"
  })
}
