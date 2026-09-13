# ------------------------------------------------------------------------------
# Auto Scaling Policies: Target Tracking at 60% CPU Utilization
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

# 3. EKS Managed Node Group Auto Scaling Policy
resource "aws_autoscaling_policy" "eks_nodes_cpu" {
  name                   = "${local.name_prefix}-eks-nodes-target-tracking-60"
  autoscaling_group_name = aws_eks_node_group.main.resources[0].autoscaling_groups[0].name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = var.autoscaling_target_cpu # 60%
  }
}
