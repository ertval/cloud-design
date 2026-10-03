# ------------------------------------------------------------------------------
# Managed RabbitMQ Broker: Amazon MQ (Private Subnet)
# ------------------------------------------------------------------------------

resource "random_password" "mq_admin" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
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
  name                    = "${local.name_prefix}-amazon-mq-credentials"
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
  # Multi-AZ standby (not SINGLE_INSTANCE SPOF); spans both private DB subnets.
  # NOTE: RabbitMQ CLUSTER_MULTI_AZ needs 3 AZs; with 2 AZs use ACTIVE_STANDBY_MULTI_AZ.
  deployment_mode = "ACTIVE_STANDBY_MULTI_AZ"

  # Deploy across private database subnets in both AZs
  subnet_ids          = aws_subnet.private_db[*].id
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
