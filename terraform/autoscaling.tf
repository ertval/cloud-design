# ------------------------------------------------------------------------------
# Auto Scaling Policies: Target Tracking
#
#   api-gateway    -> ECSServiceAverageCPUUtilization, 60%, min 1 / max 3
#   inventory-app  -> ECSServiceAverageCPUUtilization, 60%, min 1 / max 3
#   billing-app    -> Amazon MQ MessageCount (backlog), min 2 / max 6
#
# billing-app is the ONLY RabbitMQ consumer and the ONLY writer to the billing
# database, which drives two non-obvious choices:
#
#   * CPU is the WRONG signal for it. A consumer blocked on an AMQP socket is
#     idle while the backlog grows, so CPU target tracking would never react to
#     the exact condition that needs more consumers. It scales on queue depth.
#   * min_capacity is 2, never 1. One task would be a single point of failure
#     for order processing, and with prefetch_count = 1 each task holds exactly
#     one unacked message, so two tasks give AZ independence plus parallel drain
#     capacity.
#
# The signal is the broker-level AWS/AmazonMQ MessageCount metric. Amazon MQ for
# RabbitMQ does not publish per-queue CloudWatch dimensions, so this is an
# approximation of the `billing_queue` depth; it is the only backlog signal AWS
# exposes for this broker, and it is the same metric dashboarded as queue depth.
# ------------------------------------------------------------------------------

# 1. API Gateway Service Auto Scaling Target (Min: 1, Max: 3)
resource "aws_appautoscaling_target" "api_gateway" {
  max_capacity       = 3
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.api_gateway.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = [aws_ecs_service.api_gateway]
}

# Target Tracking Policy for API Gateway: 60% CPU Trigger
resource "aws_appautoscaling_policy" "api_gateway_cpu" {
  name               = "${local.name_prefix}-apigw-cpu-target-tracking-60"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.api_gateway.resource_id
  scalable_dimension = aws_appautoscaling_target.api_gateway.scalable_dimension
  service_namespace  = aws_appautoscaling_target.api_gateway.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value       = var.autoscaling_target_cpu # 60.0%
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# 2. Inventory App Service Auto Scaling Target (Min: 1, Max: 3)
resource "aws_appautoscaling_target" "inventory_app" {
  max_capacity       = 3
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.inventory_app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = [aws_ecs_service.inventory_app]
}

# Target Tracking Policy for Inventory App: 60% CPU Trigger
resource "aws_appautoscaling_policy" "inventory_app_cpu" {
  name               = "${local.name_prefix}-inventory-cpu-target-tracking-60"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.inventory_app.resource_id
  scalable_dimension = aws_appautoscaling_target.inventory_app.scalable_dimension
  service_namespace  = aws_appautoscaling_target.inventory_app.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value       = var.autoscaling_target_cpu # 60.0%
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# 3. Billing App Service Auto Scaling Target (Min: 2, Max: 6)
# The queue consumer. Scales on backlog, not on CPU - see the header.
resource "aws_appautoscaling_target" "billing_app" {
  max_capacity       = var.billing_app_max_capacity
  min_capacity       = var.billing_app_min_capacity
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.billing_app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = [aws_ecs_service.billing_app]
}

# Target Tracking Policy for Billing App: queue backlog, in messages.
resource "aws_appautoscaling_policy" "billing_app_queue_depth" {
  name               = "${local.name_prefix}-billing-queue-depth-target-tracking"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.billing_app.resource_id
  scalable_dimension = aws_appautoscaling_target.billing_app.scalable_dimension
  service_namespace  = aws_appautoscaling_target.billing_app.service_namespace

  target_tracking_scaling_policy_configuration {
    # A backlog this size is what "keeping up" means here: enough messages
    # waiting that one more consumer pays for itself immediately.
    target_value       = var.billing_queue_depth_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    customized_metric_specification {
      metric_name = "MessageCount"
      namespace   = "AWS/AmazonMQ"
      statistic   = "Average"

      dimensions {
        name  = "Broker"
        value = aws_mq_broker.rabbitmq.broker_name
      }
    }
  }
}
