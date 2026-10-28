# ------------------------------------------------------------------------------
# CloudWatch Logs, Metrics, Alarms, and Operational Dashboards
# ------------------------------------------------------------------------------

# 1. CloudWatch Log Groups with Configurable Retention
resource "aws_cloudwatch_log_group" "api_gw" {
  name              = "/aws/apigateway/${local.name_prefix}-api"
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

# FIX (was completely absent): an SNS topic with no resource policy silently
# drops every Publish. AWS Budgets publishes to this topic from the
# `budgets.amazonaws.com` service principal, and CloudWatch alarms publish from
# `cloudwatch.amazonaws.com`, so without this policy the cost and error alarms
# looked healthy in the console while notifying nobody.
data "aws_iam_policy_document" "sns_alerts" {
  statement {
    sid    = "AllowCloudWatchAlarmsToPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }

  statement {
    sid    = "AllowAwsBudgetsToPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }

  statement {
    sid    = "AllowAccountOwnersToSubscribe"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }

    actions = [
      "SNS:Subscribe",
      "SNS:ListSubscriptionsByTopic",
      "SNS:SetTopicAttributes",
      "SNS:GetTopicAttributes",
    ]

    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.sns_alerts.json
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

# Alarm: Unhealthy ALB Targets
# The single most useful ALB signal: it fires when the api-gateway tasks are
# failing their /health check (bad image, crash loop, DB unreachable) and the
# target group has nothing to serve - a condition that produces zero target 5XX
# responses precisely because no request reaches a target.
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  alarm_name          = "${local.name_prefix}-alb-unhealthy-hosts"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  alarm_description   = "ALB has at least one unhealthy api-gateway target (failing /health check)"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

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

# Alarm: ECS Service CPU Utilization
# This is the exact metric the Application Auto Scaling target-tracking policies
# in autoscaling.tf key off (ECSServiceAverageCPUUtilization is derived from it),
# so an alarm here fires at the same threshold the autoscaler reacts to.
resource "aws_cloudwatch_metric_alarm" "ecs_api_gateway_cpu" {
  alarm_name          = "${local.name_prefix}-ecs-api-gateway-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = var.autoscaling_target_cpu
  alarm_description   = "ECS api-gateway service CPU above the autoscaling target (${var.autoscaling_target_cpu}%)"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.api_gateway.name
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "ecs_inventory_app_cpu" {
  alarm_name          = "${local.name_prefix}-ecs-inventory-app-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = var.autoscaling_target_cpu
  alarm_description   = "ECS inventory-app service CPU above the autoscaling target (${var.autoscaling_target_cpu}%)"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.inventory_app.name
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

# Alarm: RDS Billing High CPU Utilization (> 80%)
# FIX: only the inventory database had CPU/storage coverage. The billing database
# is equally Multi-AZ, equally billable, and equally able to saturate - and it is
# written to by an asynchronous consumer, so a stall there is invisible in the
# request path and shows up only as an alarm (or, previously, as nothing).
resource "aws_cloudwatch_metric_alarm" "rds_billing_cpu" {
  alarm_name          = "${local.name_prefix}-rds-billing-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 120
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "RDS Billing database CPU utilization exceeds 80%"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.billing.id
  }

  tags = local.common_tags
}

# Alarm: RDS Billing Low Free Storage Space (< 5GB)
resource "aws_cloudwatch_metric_alarm" "rds_billing_low_storage" {
  alarm_name          = "${local.name_prefix}-rds-billing-low-storage"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 5368709120 # 5 GB in bytes
  alarm_description   = "RDS Billing database remaining free storage below 5GB"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.billing.id
  }

  tags = local.common_tags
}

# Alarm: billing-app running fewer consumer tasks than its minimum
# billing-app is the only RabbitMQ consumer, and none of the alarms above can
# see it: the ALB alarms watch only the api-gateway target group, and it has no
# CPU alarm. RunningTaskCount comes from Container Insights, which is already
# enabled on the cluster (orchestration.tf), so this needs no new metric.
# treat_missing_data = "breaching": with no running task there may be no data
# point at all, and silence must not read as healthy. The flip side is a short
# ALARM on the very first apply, until the first tasks report.
resource "aws_cloudwatch_metric_alarm" "billing_app_running_tasks" {
  alarm_name          = "${local.name_prefix}-billing-app-consumers-below-min"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Minimum"
  threshold           = var.billing_app_min_capacity
  treat_missing_data  = "breaching"
  alarm_description   = "billing-app (the only queue consumer) has run fewer than ${var.billing_app_min_capacity} tasks for 3 minutes; orders queue up but are not written"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.billing_app.name
  }

  tags = local.common_tags
}

# Alarm: the billing queue stays deep
# Broker-level MessageCount (ready + unacknowledged), the same metric the
# billing-app autoscaling policy tracks. Target tracking aims to hold it near
# billing_queue_depth_target, so a backlog that stays above TWICE that for 5
# minutes means added consumers are not catching up (or are not consuming at
# all). To see it fire in a drill, stop the consumers and queue more than
# 2 x billing_queue_depth_target orders. Missing data is not treated as a
# backlog: no data means no broker metrics, which this alarm cannot judge.
# Broker level, not per queue: the Queue and VirtualHost dimensions exist on
# RabbitMQ 3.x but not on 4.x brokers, and var.mq_engine_version leaves room for
# that upgrade.
resource "aws_cloudwatch_metric_alarm" "billing_queue_backlog" {
  alarm_name          = "${local.name_prefix}-billing-queue-backlog"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  metric_name         = "MessageCount"
  namespace           = "AWS/AmazonMQ"
  period              = 60
  statistic           = "Minimum"
  threshold           = var.billing_queue_depth_target * 2
  treat_missing_data  = "notBreaching"
  alarm_description   = "Broker MessageCount above ${var.billing_queue_depth_target * 2} (2 x the autoscaling target) for 5 minutes: the billing consumers are not keeping up"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    Broker = aws_mq_broker.rabbitmq.broker_name
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
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.billing.id, { stat = "Average", label = "Billing DB CPU %" }],
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
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          # FIX: these two metrics were queried with the LoadBalancer dimension
          # alone, which the ALB never publishes for them: HealthyHostCount and
          # UnHealthyHostCount exist only per target group (TargetGroup +
          # LoadBalancer, optionally + AvailabilityZone). The widget could never
          # show data. Now one line per target group and state. Minimum for
          # healthy shows any dip; Maximum for unhealthy shows any failure.
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.apigw.arn_suffix, "LoadBalancer", aws_lb.main.arn_suffix, { stat = "Minimum", label = "api-gateway healthy" }],
            [".", "UnHealthyHostCount", ".", ".", ".", ".", { stat = "Maximum", label = "api-gateway unhealthy", color = "#d62728" }],
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.billing.arn_suffix, "LoadBalancer", aws_lb.main.arn_suffix, { stat = "Minimum", label = "billing-app healthy" }],
            [".", "UnHealthyHostCount", ".", ".", ".", ".", { stat = "Maximum", label = "billing-app unhealthy", color = "#ff7f0e" }]
          ]
          view    = "timeSeries"
          stacked = false
          region  = local.region
          title   = "ALB Target Health (per target group)"
          period  = 60
          yAxis   = { left = { min = 0 } }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.api_gateway.name, { stat = "Average", label = "api-gateway CPU %" }],
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.inventory_app.name, { stat = "Average", label = "inventory-app CPU %" }],
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.billing_app.name, { stat = "Average", label = "billing-app CPU %" }]
          ]
          view    = "timeSeries"
          stacked = false
          region  = local.region
          title   = "ECS Fargate Service CPU Utilization (autoscaling input)"
          period  = 60
        }
      },
      # Logs Insights widgets: the dashboard was metrics-only, so "logging
      # dashboards" was not literally true. Each widget runs its query over the
      # dashboard's time range when the dashboard is opened or refreshed, billed
      # at the Logs Insights rate per GB scanned (fractions of a cent at demo
      # volume, nothing while nobody looks at it).
      {
        type   = "log"
        x      = 0
        y      = 18
        width  = 12
        height = 6
        properties = {
          # All three apps log "<time> [LEVEL] [service] message" (the format in
          # each srcs/*/app/__init__.py), so an [ERROR] or [CRITICAL] tag marks
          # an error line. The service name is the last part of the log group
          # name (@log), which every event carries, so lines from other loggers
          # are still counted under the right service.
          query = join("", [
            "SOURCE '${aws_cloudwatch_log_group.api_gateway_app.name}' | ",
            "SOURCE '${aws_cloudwatch_log_group.inventory_app.name}' | ",
            "SOURCE '${aws_cloudwatch_log_group.billing_app.name}' | ",
            "filter @message like /\\[(ERROR|CRITICAL)\\]/\n",
            "| parse @log /(?<service>[^\\/]+)$/\n",
            "| stats count(*) as errors by service\n",
            "| sort errors desc",
          ])
          region = local.region
          title  = "Application errors per service ([ERROR] / [CRITICAL] log lines)"
          view   = "table"
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 18
        width  = 12
        height = 6
        properties = {
          # The API Gateway access log is JSON (access_log_settings in
          # api_gateway.tf), so Logs Insights discovers status, routeKey and
          # integrationErrorMessage as fields. status is logged as a string,
          # hence the regex instead of a numeric comparison.
          query = join("", [
            "SOURCE '${aws_cloudwatch_log_group.api_gw.name}' | ",
            "filter status like /^5/\n",
            "| fields @timestamp, status, routeKey, integrationErrorMessage, requestId\n",
            "| sort @timestamp desc\n",
            "| limit 20",
          ])
          region = local.region
          title  = "Recent 5xx responses at API Gateway (access log)"
          view   = "table"
        }
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# 5. AWS Budgets & CloudWatch Billing Alarms (Actionable Cost Management Plan)
# ------------------------------------------------------------------------------
# The default limit, the line-item estimate behind it and the reasoning for the
# thresholds below all live in one place, var.monthly_budget_limit, so they
# cannot drift apart again (this comment used to repeat an old 300 USD default
# and a 260 USD steady state). The previous default of 15 USD was ~20x below the
# real run-rate, so this alarm fired every single month and taught an auditor
# nothing.

resource "aws_budgets_budget" "monthly" {
  name         = "${local.name_prefix}-monthly-budget"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_limit)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.alarm_email != "" ? [var.alarm_email] : []
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.alarm_email != "" ? [var.alarm_email] : []
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
  }

  tags = local.common_tags
}

# CloudWatch Billing Metric Alarm for EstimatedCharges
resource "aws_cloudwatch_metric_alarm" "billing_estimated_charges" {
  alarm_name          = "${local.name_prefix}-estimated-charges-limit"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 21600 # 6 hours
  statistic           = "Maximum"
  threshold           = var.monthly_budget_limit
  # FIX: the original used "$${var.monthly_budget_limit}". The doubled dollar
  # escapes the interpolation, so the alarm description rendered the literal
  # string "${var.monthly_budget_limit}" and never mentioned a number. A single
  # "$" interpolates normally, and the interpolation consumes it, so no dollar
  # sign is left in the text; the unit is therefore spelled out after the number,
  # and with the default this reads "... exceeds 450 USD".
  alarm_description = "Proactive alarm triggered when estimated monthly AWS infrastructure spend exceeds ${var.monthly_budget_limit} USD"
  alarm_actions     = [aws_sns_topic.alerts.arn]

  dimensions = {
    Currency = "USD"
  }

  tags = local.common_tags
}
