# ------------------------------------------------------------------------------
# ECS Task Definitions & Services Backing the Application Auto Scaling Targets
# ------------------------------------------------------------------------------
# autoscaling.tf resource_ids must resolve to real services for `terraform
# validate` / apply; names match local.name_prefix convention used there.
#
# Three services, matching the three applications in srcs/:
#   api-gateway  : public through API Gateway, behind the internal ALB target group (:3000)
#   inventory-app: private, discovered by api-gateway over Cloud Map (:8080)
#   billing-app  : private, the ONLY RabbitMQ consumer, and additionally behind
#                  a second ALB target group (:8080) so GET /api/billing/orders
#                  is reachable
# All three start with 2 tasks (one per private app subnet) and autoscaling.tf
# owns desiredCount after that, which is why each has ignore_changes.
# ------------------------------------------------------------------------------

locals {
  # Image URLs come from the ECR repositories themselves (ecr.tf) rather than
  # being reconstructed by hand, so the task definitions can never point at a
  # registry path that Terraform does not manage.
  # FIX: the tag was a hard-coded :latest while scripts/build_push.sh pushed
  # :local, so no task could pull its image. The script now pushes :latest plus
  # the git short SHA, and the tag here is var.image_tag (default "latest").
  ecr_image_urls = {
    for name, repo in aws_ecr_repository.app :
    name => "${repo.repository_url}:${var.image_tag}"
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
  # billing-app stays on /health although its /ready also checks the queue
  # consumer: a failing ECS health check replaces the task, and replacing
  # consumers cannot fix a broker outage (a single-instance broker can also be
  # down during its weekly maintenance window). A lost broker shows in the task
  # logs and in the billing-queue-backlog alarm instead.
  health_checks = {
    api-gateway   = "python -c \"import urllib.request as u; u.urlopen('http://127.0.0.1:3000/health', timeout=3)\""
    inventory-app = "python -c \"import urllib.request as u; u.urlopen('http://127.0.0.1:8080/health', timeout=3)\""
    billing-app   = "python -c \"import urllib.request as u; u.urlopen('http://127.0.0.1:8080/health', timeout=3)\""
  }

  # db-role-init: the first container of the inventory-app and billing-app
  # tasks. It creates or updates the app's own least-privilege PostgreSQL role
  # (files/db_role_init.py; the role model is described next to
  # local.db_app_users in rds.tf) and exits. It runs from the app's own image,
  # which already has psycopg2, so no extra image is pulled. The app container
  # starts only after it exits 0 (dependsOn SUCCESS), and only this container
  # receives the master secret; the app container gets the app role's secret.
  db_role_init_script = file("${path.module}/files/db_role_init.py")
  db_role_init_containers = {
    for app, db in {
      inventory-app = {
        address       = aws_db_instance.inventory.address
        port          = aws_db_instance.inventory.port
        database      = "inventory_db"
        master_secret = aws_secretsmanager_secret.inventory_db.arn
        app_secret    = aws_secretsmanager_secret.inventory_app_db.arn
        log_group     = aws_cloudwatch_log_group.inventory_app.name
      }
      billing-app = {
        address       = aws_db_instance.billing.address
        port          = aws_db_instance.billing.port
        database      = "billing_db"
        master_secret = aws_secretsmanager_secret.billing_db.arn
        app_secret    = aws_secretsmanager_secret.billing_app_db.arn
        log_group     = aws_cloudwatch_log_group.billing_app.name
      }
    } :
    app => {
      name      = "db-role-init"
      image     = local.ecr_image_urls[app]
      essential = false
      command   = ["python3", "-c", local.db_role_init_script]
      environment = [
        { name = "DB_HOST", value = db.address },
        { name = "DB_PORT", value = tostring(db.port) },
        { name = "DB_NAME", value = db.database }
      ]
      secrets = [
        { name = "MASTER_DB_USER", valueFrom = "${db.master_secret}:username::" },
        { name = "MASTER_DB_PASSWORD", valueFrom = "${db.master_secret}:password::" },
        { name = "APP_DB_USER", valueFrom = "${db.app_secret}:username::" },
        { name = "APP_DB_PASSWORD", valueFrom = "${db.app_secret}:password::" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = db.log_group
          awslogs-region        = local.region
          awslogs-stream-prefix = "db-role-init"
        }
      }
    }
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
      name      = "api-gateway"
      image     = local.ecr_image_urls["api-gateway"]
      essential = true
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
        { name = "RABBITMQ_QUEUE", value = "billing_queue" }
      ]
      secrets = [
        # FIX: RABBITMQ_USER used to be a plaintext `environment` entry. Anyone
        # holding ecs:DescribeTaskDefinition can read a task definition, so a
        # username injected as plaintext env is readable by every principal that
        # can describe tasks, and it is stored verbatim in the task definition
        # revision. The `username` key was already present in the secret JSON
        # (amazon_mq.tf) and simply unused. valueFrom syntax is
        # "<secret-arn>:<json-key>::" - the empty version/json-path stages take
        # the whole top-level value of `username`.
        { name = "RABBITMQ_USER", valueFrom = "${aws_secretsmanager_secret.mq_credentials.arn}:username::" },
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
    local.db_role_init_containers["inventory-app"],
    {
      name      = "inventory-app"
      image     = local.ecr_image_urls["inventory-app"]
      essential = true
      dependsOn = [{ containerName = "db-role-init", condition = "SUCCESS" }]
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
        # TLS or no connection, from the client side too (RDS enforces it with
        # rds.force_ssl, rds.tf). Also the code default; set here so the task
        # definition shows it.
        { name = "DB_SSLMODE", value = "require" }
      ]
      secrets = [
        # FIX: INVENTORY_DB_USER moved out of plaintext `environment` into the
        # `username` key of the secret that already carried it (rds.tf) - see the
        # RABBITMQ_USER note in the api-gateway task definition for why.
        # The app role's secret, not the master secret: inventory_app can only
        # use its own tables (db-role-init above).
        { name = "INVENTORY_DB_USER", valueFrom = "${aws_secretsmanager_secret.inventory_app_db.arn}:username::" },
        { name = "INVENTORY_DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.inventory_app_db.arn}:password::" }
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

  # Both containers read these secrets' values at launch, so the values must
  # exist before ECS can start a task from this definition.
  depends_on = [
    aws_secretsmanager_secret_version.inventory_db,
    aws_secretsmanager_secret_version.inventory_app_db,
  ]

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
    local.db_role_init_containers["billing-app"],
    {
      name      = "billing-app"
      image     = local.ecr_image_urls["billing-app"]
      essential = true
      dependsOn = [{ containerName = "db-role-init", condition = "SUCCESS" }]
      portMappings = [
        { containerPort = 8080, hostPort = 8080, protocol = "tcp" }
      ]
      environment = [
        { name = "APP_PORT", value = "8080" },
        { name = "BILLING_DB_HOST", value = aws_db_instance.billing.address },
        { name = "BILLING_DB_PORT", value = tostring(aws_db_instance.billing.port) },
        { name = "BILLING_DB_NAME", value = "billing_db" },
        { name = "DB_SSLMODE", value = "require" },
        { name = "RABBITMQ_HOST", value = local.mq_amqps_host },
        { name = "RABBITMQ_PORT", value = "5671" },
        { name = "RABBITMQ_QUEUE", value = "billing_queue" }
      ]
      secrets = [
        # FIX: BILLING_DB_USER and RABBITMQ_USER moved out of plaintext
        # `environment` into the `username` key of the secrets that already
        # carried them (rds.tf, amazon_mq.tf). The database pair comes from the
        # app role's secret, not the master secret (db-role-init above).
        { name = "BILLING_DB_USER", valueFrom = "${aws_secretsmanager_secret.billing_app_db.arn}:username::" },
        { name = "BILLING_DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.billing_app_db.arn}:password::" },
        { name = "RABBITMQ_USER", valueFrom = "${aws_secretsmanager_secret.mq_credentials.arn}:username::" },
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

  # See the inventory-app task definition: the secret values must exist first.
  depends_on = [
    aws_secretsmanager_secret_version.billing_db,
    aws_secretsmanager_secret_version.billing_app_db,
  ]

  tags = local.common_tags
}

# ------------------------------------------------------------------------------
# Services
# ------------------------------------------------------------------------------

resource "aws_ecs_service" "api_gateway" {
  name            = "${local.name_prefix}-api-gateway"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api_gateway.arn
  # FIX: was 1. Two tasks, matching min_capacity = 2 in autoscaling.tf: the
  # internal ALB needs at least two targets to have anything to balance, and
  # Fargate spreads a service's tasks across the AZs of its subnets, so one per
  # private app subnet means an AZ loss halves the request path instead of
  # removing it. Each extra 0.25 vCPU / 0.5 GB task is about $9/month.
  desired_count = 2
  launch_type   = local.fargate_launch_type

  # FIX: aws_appautoscaling_target.api_gateway owns this service's desiredCount,
  # and Terraform and the autoscaler were fighting over it - after any scale-out
  # the next plan wanted to set it back to 1 and the apply quietly scaled the
  # service in behind the autoscaler's back.
  # `ignore_changes` rather than dropping `desired_count`: the CreateService
  # default for desiredCount is 0, so a service created without it starts with NO
  # running tasks, and a target-tracking policy keyed on ECSServiceAverageCPUUtilization
  # has no metric to react to with zero tasks - it would never scale out.
  # 2 is the create-time value, autoscaling keeps it afterwards. On a stack that
  # already runs 1 task, ignore_changes means Terraform does not send the new
  # count, but raising min_capacity does: RegisterScalableTarget moves a current
  # capacity that is below the new minimum up to it.
  lifecycle {
    ignore_changes = [desired_count]
  }

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

  # Grace period covering the cold-start database wait - see the long comment on
  # aws_ecs_service.inventory_app below. 360 s, not 60: the container's own
  # health check fails every 30 s from the moment the task starts, because the
  # Flask app does not bind :8080 until its PostgreSQL retry loop gives up or
  # succeeds, and on a cold `terraform apply` RDS is created in the same run.
  health_check_grace_period_seconds = 360
  enable_execute_command            = true

  depends_on = [aws_lb_listener.main]

  tags = local.common_tags
}

resource "aws_ecs_service" "inventory_app" {
  name            = "${local.name_prefix}-inventory-app"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.inventory_app.arn
  # FIX: was 1. Two tasks for the same reason as api-gateway above: every
  # /api/movies request goes through this service, so with one task an AZ loss
  # took the whole read/write path down.
  desired_count = 2
  launch_type   = local.fargate_launch_type

  # Same autoscaler conflict as api-gateway above
  # (aws_appautoscaling_target.inventory_app). See that comment.
  lifecycle {
    ignore_changes = [desired_count]
  }

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

  # FIX (was missing, and the "no health_check_grace_period_seconds here"
  # comment was wrong): the container probe (startPeriod 40 + interval 30 x
  # retries 3) fails at roughly 130 s, but inventory-app does not bind :8080 until
  # create_app() finishes its retry loop - DB_CONNECT_MAX_RETRIES(180) x
  # DB_CONNECT_RETRY_DELAY(2) = 360 s of budget, needed because RDS is created in
  # the same apply and a cold PostgreSQL can need a minute or more before it accepts
  # connections. Without a grace period covering that wait, ECS killed the task
  # during the DB connect on exactly the run where the DB was slowest.
  # The removed comment claimed AWS only allows this argument on load-balancer-
  # backed services. CreateService says otherwise - healthCheckGracePeriodSeconds
  # is "the period of time ... that the Amazon ECS service scheduler ignores
  # unhealthy Elastic Load Balancing, VPC Lattice, and CONTAINER health checks
  # after a task has first started", and this service has a container health check
  # in its task definition.
  health_check_grace_period_seconds = 360
  enable_execute_command            = true

  tags = local.common_tags
}

# desired_count = 2, not 1: this is the sole consumer of the billing queue and
# the sole writer to the billing database. With RDS Multi-AZ the database
# survives an AZ failure, but a single consumer task does not - and each task
# holds a prefetch window of one unacked message, so two tasks also give the
# queue parallel drain capacity. 2 matches billing_app_min_capacity in
# autoscaling.tf, where this service DOES have a policy - it scales on
# MessageCount backlog rather than CPU, because a consumer blocked on an AMQP
# socket is idle while the backlog grows.
resource "aws_ecs_service" "billing_app" {
  name            = "${local.name_prefix}-billing-app"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.billing_app.arn
  desired_count   = 2
  launch_type     = local.fargate_launch_type

  # FIX: this service was the one without ignore_changes, although
  # aws_appautoscaling_target.billing_app owns its desiredCount just like the
  # other two. So the first `terraform apply` after a backlog scale-out set it
  # back to 2 in the middle of the burst it was scaled out for, and the policy
  # had to scale out again. 2 is now only the create-time value.
  lifecycle {
    ignore_changes = [desired_count]
  }

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

  # FIX: billing-app's HTTP surface (GET /api/billing/orders) was registered with
  # Cloud Map but nothing called it, so it was unreachable through API Gateway.
  # Registering it with the second ALB target group is what makes
  # aws_lb_listener_rule.billing_orders deliver those requests; no change to
  # srcs/ was needed, which matters because that directory is owned by another
  # team. The matching SG rules are app_ingress_from_alb_billing and
  # alb_egress_to_billing_app.
  load_balancer {
    target_group_arn = aws_lb_target_group.billing.arn
    container_name   = "billing-app"
    container_port   = 8080
  }

  # Same 360 s cold-start reasoning as inventory_app above: this app also blocks in
  # create_app() on a PostgreSQL retry loop before it binds :8080, and it is
  # pinned at 2 tasks so a killed task is also a slower recovery.
  health_check_grace_period_seconds = 360
  enable_execute_command            = true

  # ECS may only register targets with an ALB once the listener exists.
  depends_on = [aws_lb_listener.main]

  tags = local.common_tags
}
