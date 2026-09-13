# ------------------------------------------------------------------------------
# ECS Task Definitions & Services backing Application Auto Scaling targets
# (autoscaling.tf resource_ids must resolve to real services for `terraform
# validate` / apply; names match local.name_prefix convention used there)
# ------------------------------------------------------------------------------

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
      name      = "api-gateway"
      image     = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com/cloud-design/api-gateway:latest"
      essential = true
      portMappings = [
        { containerPort = 3000, hostPort = 3000, protocol = "tcp" }
      ]
      environment = [
        { name = "APP_PORT", value = "3000" },
        { name = "INVENTORY_APP_PORT", value = "8080" },
        { name = "RABBITMQ_PORT", value = "5672" }
      ]
      secrets = [
        { name = "RABBITMQ_PASSWORD", valueFrom = "${aws_secretsmanager_secret.mq_credentials.arn}:password::" }
      ]
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
      name      = "inventory-app"
      image     = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com/cloud-design/inventory-app:latest"
      essential = true
      portMappings = [
        { containerPort = 8080, hostPort = 8080, protocol = "tcp" }
      ]
      environment = [
        { name = "APP_PORT", value = "8080" },
        { name = "INVENTORY_DB_PORT", value = "5432" },
        { name = "INVENTORY_DB_NAME", value = "inventory_db" }
      ]
      secrets = [
        { name = "INVENTORY_DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.inventory_db.arn}:password::" }
      ]
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

resource "aws_ecs_service" "api_gateway" {
  name            = "${local.name_prefix}-api-gateway"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api_gateway.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private_app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.apigw.arn
    container_name   = "api-gateway"
    container_port   = 3000
  }

  depends_on = [aws_lb_listener.https]

  tags = local.common_tags
}

resource "aws_ecs_service" "inventory_app" {
  name            = "${local.name_prefix}-inventory-app"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.inventory_app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private_app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  tags = local.common_tags
}
