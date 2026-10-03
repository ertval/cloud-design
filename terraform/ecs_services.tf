# ------------------------------------------------------------------------------
# ECS Task Definitions & Services Backing the Application Auto Scaling Targets
# ------------------------------------------------------------------------------
# autoscaling.tf resource_ids must resolve to real services for `terraform
# validate` / apply; names match local.name_prefix convention used there.
#
# Three services, matching the three applications in srcs/:
#   api-gateway  : internet-facing, behind the ALB target group (:3000)
#   inventory-app: private, discovered by api-gateway over Cloud Map (:8080)
#   billing-app  : private, the ONLY RabbitMQ consumer -> desired_count 2
# ------------------------------------------------------------------------------

locals {
  # Image URLs come from the ECR repositories themselves (ecr.tf) rather than
  # being reconstructed by hand, so the task definitions can never point at a
  # registry path that Terraform does not manage.
  ecr_image_urls = {
    for name, repo in aws_ecr_repository.app :
    name => "${repo.repository_url}:latest"
  }

  # launch_type and capacity_provider_strategy are mutually exclusive on
  # aws_ecs_service, so a `dynamic` block emits exactly one of the two depending
  # on the toggle (a plain conditional block would still be sent to the API with
  # a null capacity_provider). This is what makes the FARGATE_SPOT capacity
  # provider in orchestration.tf live code instead of dead configuration.
  fargate_launch_type = var.ecs_use_fargate_spot ? null : "FARGATE"

  # Container health checks. Python is guaranteed present in every image, so a
  # urllib probe works without adding curl/wget to the Dockerfiles (owned by
  # another team). These feed Cloud Map's health_check_custom_config so an
  # unhealthy task stops being returned by VPC DNS.
  health_checks = {
    api-gateway   = "python -c \"import urllib.request as u; u.urlopen('http://127.0.0.1:3000/health', timeout=3)\""
    inventory-app = "python -c \"import urllib.request as u; u.urlopen('http://127.0.0.1:8080/health', timeout=3)\""
    billing-app   = "python -c \"import urllib.request as u; u.urlopen('http://127.0.0.1:8080/health', timeout=3)\""
  }
}

resource "aws_ecs_task_definition" "api_gateway" {
  family                   = "${local.name_prefix}-api-gateway"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name         = "api-gateway"
      image        = local.ecr_image_urls["api-gateway"]
      essential    = true
      portMappings = [
        { containerPort = 3000, hostPort = 3000, protocol = "tcp" }
      ]
      environment = [
        { name = "APP_PORT", value = "3000" },
        # Cloud Map DNS name for inventory-app (service_discovery.tf).
        { name = "INVENTORY_APP_HOST", value = "inventory-app.${aws_service_discovery_private_dns_namespace.main.name}" },
        { name = "INVENTORY_APP_PORT", value = "8080" },
        # Amazon MQ for RabbitMQ speaks AMQPS on 5671 only; see the comment on
        # aws_security_group_rule.app_egress_to_mq_amqps.
        { name = "RABBITMQ_HOST", value = local.mq_amqps_host },
        { name = "RABBITMQ_PORT", value = "5671" },
        { name = "RABBITMQ_USER", value = var.mq_user },
        { name = "RABBITMQ_QUEUE", value = "billing_queue" }
      ]
      secrets = [
        { name = "RABBITMQ_PASSWORD", valueFrom = "${aws_secretsmanager_secret.mq_credentials.arn}:password::" }
      ]
      healthCheck = {
        command     = ["CMD-SHELL", local.health_checks["api-gateway"]]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.api_gateway_app.name
          awslogs-region        = local.region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  tags = local.common_tags
}

resource "aws_ecs_task_definition" "inventory_app" {
  family                   = "${local.name_prefix}-inventory-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name         = "inventory-app"
      image        = local.ecr_image_urls["inventory-app"]
      essential    = true
      portMappings = [
        { containerPort = 8080, hostPort = 8080, protocol = "tcp" }
      ]
      environment = [
        { name = "APP_PORT", value = "8080" },
        # FIX: these three were absent, so the container fell back to its
        # hard-coded defaults ("inventory-database" / "inventory_user") and could
        # never resolve or authenticate against the RDS instance.
        { name = "INVENTORY_DB_HOST", value = aws_db_instance.inventory.address },
        { name = "INVENTORY_DB_PORT", value = tostring(aws_db_instance.inventory.port) },
        { name = "INVENTORY_DB_NAME", value = "inventory_db" },
        { name = "INVENTORY_DB_USER", value = var.db_username }
      ]
      secrets = [
        { name = "INVENTORY_DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.inventory_db.arn}:password::" }
      ]
      healthCheck = {
        command     = ["CMD-SHELL", local.health_checks["inventory-app"]]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 40
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.inventory_app.name
          awslogs-region        = local.region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  tags = local.common_tags
}

# The RabbitMQ consumer and the writer to the billing database. Without this
# service the queue is never drained and no orders are ever persisted, however
# healthy the rest of the stack looks.
resource "aws_ecs_task_definition" "billing_app" {
  family                   = "${local.name_prefix}-billing-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name         = "billing-app"
      image        = local.ecr_image_urls["billing-app"]
      essential    = true
      portMappings = [
        { containerPort = 8080, hostPort = 8080, protocol = "tcp" }
      ]
      environment = [
        { name = "APP_PORT", value = "8080" },
        { name = "BILLING_DB_HOST", value = aws_db_instance.billing.address },
        { name = "BILLING_DB_PORT", value = tostring(aws_db_instance.billing.port) },
        { name = "BILLING_DB_NAME", value = "billing_db" },
        { name = "BILLING_DB_USER", value = var.db_username },
        { name = "RABBITMQ_HOST", value = local.mq_amqps_host },
        { name = "RABBITMQ_PORT", value = "5671" },
        { name = "RABBITMQ_USER", value = var.mq_user },
        { name = "RABBITMQ_QUEUE", value = "billing_queue" }
      ]
      secrets = [
        { name = "BILLING_DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.billing_db.arn}:password::" },
        { name = "RABBITMQ_PASSWORD", valueFrom = "${aws_secretsmanager_secret.mq_credentials.arn}:password::" }
      ]
      healthCheck = {
        command     = ["CMD-SHELL", local.health_checks["billing-app"]]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 40
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.billing_app.name
          awslogs-region        = local.region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  tags = local.common_tags
}

# ------------------------------------------------------------------------------
# Services
# ------------------------------------------------------------------------------

resource "aws_ecs_service" "api_gateway" {
  name            = "${local.name_prefix}-api-gateway"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api_gateway.arn
  desired_count   = 1
  launch_type     = local.fargate_launch_type

  dynamic "capacity_provider_strategy" {
    for_each = var.ecs_use_fargate_spot ? [1] : []
    content {
      capacity_provider = "FARGATE_SPOT"
      weight            = 1
      base              = 0
    }
  }

  network_configuration {
    subnets          = aws_subnet.private_app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  # ALB target-group registration: how internet traffic reaches api-gateway.
  load_balancer {
    target_group_arn = aws_lb_target_group.apigw.arn
    container_name   = "api-gateway"
    container_port   = 3000
  }

  # Cloud Map registration: how inventory-app reaches api-gateway by DNS.
  service_registries {
    registry_arn   = aws_service_discovery_service.app["api-gateway"].arn
    container_name = "api-gateway"
    container_port = 3000
  }

  # Grace period for the ALB health checks declared in alb.tf. Only meaningful on
  # a service that has a load_balancer block, which is why the two private
  # services below deliberately do not set it.
  health_check_grace_period_seconds = 60
  enable_execute_command            = true

  depends_on = [aws_lb_listener.https]

  tags = local.common_tags
}

resource "aws_ecs_service" "inventory_app" {
  name            = "${local.name_prefix}-inventory-app"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.inventory_app.arn
  desired_count   = 1
  launch_type     = local.fargate_launch_type

  dynamic "capacity_provider_strategy" {
    for_each = var.ecs_use_fargate_spot ? [1] : []
    content {
      capacity_provider = "FARGATE_SPOT"
      weight            = 1
      base              = 0
    }
  }

  network_configuration {
    subnets          = aws_subnet.private_app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  # This is the record api-gateway resolves via INVENTORY_APP_HOST.
  service_registries {
    registry_arn   = aws_service_discovery_service.app["inventory-app"].arn
    container_name = "inventory-app"
    container_port = 8080
  }

  # No health_check_grace_period_seconds here: AWS documents that argument as
  # valid only for services with a load balancer, and these two are discovered
  # through Cloud Map instead. Their health gating comes from the container
  # healthCheck in the task definition.
  enable_execute_command = true

  tags = local.common_tags
}

# desired_count = 2, not 1: this is the sole consumer of the billing queue and
# the sole writer to the billing database. With RDS Multi-AZ the database
# survives an AZ failure, but a single consumer task does not - and each task
# holds a prefetch window of one unacked message, so two tasks also give the
# queue parallel drain capacity. Left out of autoscaling.tf on purpose: it must
# not scale to zero while messages are queued.
resource "aws_ecs_service" "billing_app" {
  name            = "${local.name_prefix}-billing-app"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.billing_app.arn
  desired_count   = 2
  launch_type     = local.fargate_launch_type

  dynamic "capacity_provider_strategy" {
    for_each = var.ecs_use_fargate_spot ? [1] : []
    content {
      capacity_provider = "FARGATE_SPOT"
      weight            = 1
      base              = 0
    }
  }

  network_configuration {
    subnets          = aws_subnet.private_app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn   = aws_service_discovery_service.app["billing-app"].arn
    container_name = "billing-app"
    container_port = 8080
  }

  # No health_check_grace_period_seconds here: AWS documents that argument as
  # valid only for services with a load balancer, and these two are discovered
  # through Cloud Map instead. Their health gating comes from the container
  # healthCheck in the task definition.
  enable_execute_command = true

  tags = local.common_tags
}
