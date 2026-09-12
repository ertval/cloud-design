# ------------------------------------------------------------------------------
# CloudWatch Logs, Metrics, Alarms, and Operational Dashboards
# ------------------------------------------------------------------------------

# 1. CloudWatch Log Groups with Configurable Retention
resource "aws_cloudwatch_log_group" "api_gw" {
  name              = "/aws/apigateway/${local.name_prefix}-api"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${local.name_prefix}-eks/cluster"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "api_gateway_app" {
  name              = "/aws/microservices/${local.name_prefix}/api-gateway"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "inventory_app" {
  name              = "/aws/microservices/${local.name_prefix}/inventory-app"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "billing_app" {
  name              = "/aws/microservices/${local.name_prefix}/billing-app"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

# 2. SNS Alert Topic for SRE & DevOps Incident Notifications
resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-operational-alerts"
  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# 3. CloudWatch Metric Alarms

# Alarm: API Gateway 5XX Errors
resource "aws_cloudwatch_metric_alarm" "api_5xx_errors" {
  alarm_name          = "${local.name_prefix}-apigw-high-5xx-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "5xx"
  namespace           = "AWS/ApiGateway"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Triggered when API Gateway encounters > 5 server errors within 2 minutes"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    ApiId = aws_apigatewayv2_api.main.id
  }

  tags = local.common_tags
}

# Alarm: ALB Target 5XX Error Rate
resource "aws_cloudwatch_metric_alarm" "alb_target_5xx" {
  alarm_name          = "${local.name_prefix}-alb-target-5xx-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Triggered when ALB target microservice containers return 5XX responses"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.apigw.arn_suffix
  }

  tags = local.common_tags
}

# Alarm: High Target Response Time (Latency > 1s)
resource "aws_cloudwatch_metric_alarm" "alb_latency" {
  alarm_name          = "${local.name_prefix}-alb-high-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 1.0 # 1 second
  alarm_description   = "Triggered when microservice response latency exceeds 1 second"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.apigw.arn_suffix
  }

  tags = local.common_tags
}

# Alarm: RDS High CPU Utilization (> 80%)
resource "aws_cloudwatch_metric_alarm" "rds_inventory_cpu" {
  alarm_name          = "${local.name_prefix}-rds-inventory-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 120
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "RDS Inventory database CPU utilization exceeds 80%"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.inventory.id
  }

  tags = local.common_tags
}

# Alarm: RDS Low Free Storage Space (< 5GB)
resource "aws_cloudwatch_metric_alarm" "rds_inventory_low_storage" {
  alarm_name          = "${local.name_prefix}-rds-inventory-low-storage"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 5368709120 # 5 GB in bytes
  alarm_description   = "RDS Inventory database remaining free storage below 5GB"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.inventory.id
  }

  tags = local.common_tags
}

# 4. Centralized CloudWatch Operational Dashboard
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name_prefix}-observability"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", aws_apigatewayv2_api.main.id, { stat = "Sum", label = "API Gateway Requests" }],
            [".", "4xx", ".", ".", { stat = "Sum", color = "#ff7f0e", label = "4XX Client Errors" }],
            [".", "5xx", ".", ".", { stat = "Sum", color = "#d62728", label = "5XX Server Errors" }]
          ]
          view    = "timeSeries"
          stacked = false
          region  = local.region
          title   = "API Gateway Traffic & Error Status Codes"
          period  = 60
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.main.arn_suffix, { stat = "Sum" }],
            [".", "TargetResponseTime", ".", ".", { stat = "Average", yAxis = "right" }]
          ]
          view    = "timeSeries"
          stacked = false
          region  = local.region
          title   = "ALB Request Volume and Target Response Latency"
          period  = 60
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.inventory.id, { stat = "Average", label = "Inventory DB CPU %" }],
            [".", "DatabaseConnections", ".", ".", { stat = "Average", yAxis = "right", label = "Inventory Connections" }],
            [".", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.billing.id, { stat = "Average", label = "Billing DB CPU %" }],
            [".", "DatabaseConnections", ".", ".", { stat = "Average", yAxis = "right", label = "Billing Connections" }]
          ]
          view    = "timeSeries"
          stacked = false
          region  = local.region
          title   = "RDS PostgreSQL Database Health (CPU & Connections)"
          period  = 60
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/AmazonMQ", "MessageCount", "Broker", aws_mq_broker.rabbitmq.broker_name, { stat = "Average", label = "RabbitMQ Queue Depth" }]
          ]
          view    = "timeSeries"
          stacked = false
          region  = local.region
          title   = "Amazon MQ RabbitMQ Queue Throughput"
          period  = 60
        }
      }
    ]
  })
}
