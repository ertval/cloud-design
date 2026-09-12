# ------------------------------------------------------------------------------
# Managed RabbitMQ Broker: Amazon MQ (Private Subnet)
# ------------------------------------------------------------------------------

resource "random_password" "mq_admin" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
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
  deployment_mode    = "SINGLE_INSTANCE"

  # Deploy exclusively in private database subnet
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
