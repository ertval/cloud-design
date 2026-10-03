# ------------------------------------------------------------------------------
# Terraform Outputs
# ------------------------------------------------------------------------------
# The EKS outputs were removed with the EKS path. `cognito_user_pool_domain` was
# added because without it the hosted-UI login URL cannot be assembled, which
# makes the Cognito control impossible to demonstrate at audit.
# ------------------------------------------------------------------------------

# Networking Outputs
output "vpc_id" {
  description = "The ID of the provisioned Virtual Private Cloud"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "private_app_subnet_ids" {
  description = "List of private application subnet IDs"
  value       = aws_subnet.private_app[*].id
}

output "private_db_subnet_ids" {
  description = "List of private database subnet IDs"
  value       = aws_subnet.private_db[*].id
}

output "availability_zones_in_use" {
  description = "Availability zones the subnets were actually placed in (discovered or pinned)"
  value       = local.availability_zones
}

# Entrypoint / Gateway Outputs
output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "alb_arn" {
  description = "ARN of the Application Load Balancer"
  value       = aws_lb.main.arn
}

output "alb_https_url" {
  description = "Public HTTPS base URL of the ALB (custom domain when enable_acm_certificate = true, otherwise the ALB DNS name)"
  value       = local.alb_base_url
}

output "alb_certificate_arn" {
  description = "ARN of the certificate the ALB HTTPS listener terminates with"
  value       = local.alb_certificate_arn
}

output "api_gateway_invoke_url" {
  description = "HTTPS invoke URL for the Amazon API Gateway"
  value       = aws_apigatewayv2_api.main.api_endpoint
}

output "app_base_url" {
  description = "Base URL of the protected /api/movies resource through API Gateway"
  value       = "${aws_apigatewayv2_api.main.api_endpoint}/api/movies"
}

output "app_base_url_via_alb" {
  description = "Base URL of the protected /api/movies resource reached directly at the ALB (bypasses the Cognito authorizer, so it is unauthenticated)"
  value       = "${local.alb_base_url}/api/movies"
}

# Authentication Outputs (AWS Cognito)
output "cognito_user_pool_id" {
  description = "AWS Cognito User Pool ID"
  value       = aws_cognito_user_pool.main.id
}

output "cognito_user_pool_domain" {
  description = "Cognito hosted-UI domain (without scheme). Combine with cognito_issuer_url to build the /login URL an auditor needs to obtain a JWT."
  value       = aws_cognito_user_pool_domain.main.domain
}

output "cognito_hosted_ui_url" {
  description = "Cognito hosted-UI login URL"
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${local.region}.amazoncognito.com/login"
}

output "cognito_user_pool_client_id" {
  description = "AWS Cognito User Pool Client ID (public PKCE client used by the frontend)"
  value       = aws_cognito_user_pool_client.main.id
}

output "cognito_demo_client_id" {
  description = "Client ID of the confidential demo client used for `initiate-auth` in the audit walkthrough"
  value       = try(aws_cognito_user_pool_client.demo[0].id, null)
}

output "cognito_demo_user_email" {
  description = "Username of the optional demo Cognito user"
  value       = var.enable_demo_cognito_user ? var.demo_user_email : null
}

output "cognito_demo_user_password" {
  description = "Password of the optional demo Cognito user. Sensitive: it exists in Terraform state either way, which is why enable_demo_cognito_user should be false outside a demo."
  value       = local.demo_user_password
  sensitive   = true
}

output "cognito_issuer_url" {
  description = "Cognito Token Issuer URL (the JWT `iss` claim the authorizer validates)"
  value       = "https://${aws_cognito_user_pool.main.endpoint}"
}

# Database Outputs (Amazon RDS)
output "rds_inventory_endpoint" {
  description = "Connection endpoint address for the RDS Inventory PostgreSQL database"
  value       = aws_db_instance.inventory.address
}

output "rds_billing_endpoint" {
  description = "Connection endpoint address for the RDS Billing PostgreSQL database"
  value       = aws_db_instance.billing.address
}

output "rds_parameter_group_name" {
  description = "PostgreSQL parameter group enforcing rds.force_ssl = 1"
  value       = aws_db_parameter_group.postgres.name
}

# Messaging Outputs (Amazon MQ)
output "amazon_mq_broker_id" {
  description = "Amazon MQ RabbitMQ Broker ID"
  value       = aws_mq_broker.rabbitmq.id
}

output "amazon_mq_endpoints" {
  description = "Amazon MQ RabbitMQ Broker AMQP/Management endpoints"
  value       = try(aws_mq_broker.rabbitmq.instances[0].endpoints, [])
}

output "amazon_mq_amqps_host" {
  description = "Bare AMQPS hostname injected into the containers as RABBITMQ_HOST (port is always 5671 for Amazon MQ RabbitMQ)"
  value       = local.mq_amqps_host
}

# Container Registry Outputs
output "ecr_registry_url" {
  description = "Account/region ECR registry prefix, e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com"
  value       = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"
}

output "ecr_repository_urls" {
  description = "Map of application name to the full ECR image URL used by the ECS task definitions"
  value       = local.ecr_image_urls
}

# Service Discovery Outputs
output "service_discovery_namespace" {
  description = "Cloud Map private DNS namespace"
  value       = aws_service_discovery_private_dns_namespace.main.name
}

output "inventory_app_internal_url" {
  description = "In-VPC URL api-gateway uses to reach inventory-app"
  value       = "http://inventory-app.${aws_service_discovery_private_dns_namespace.main.name}:8080"
}

# Orchestration Outputs
output "ecs_cluster_name" {
  description = "Amazon ECS Cluster Name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_names" {
  description = "Names of the ECS services running on Fargate"
  value = {
    api-gateway   = aws_ecs_service.api_gateway.name
    inventory-app = aws_ecs_service.inventory_app.name
    billing-app   = aws_ecs_service.billing_app.name
  }
}

# Observability Outputs
output "cloudwatch_dashboard_name" {
  description = "Name of the CloudWatch centralized operational dashboard"
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}

output "sns_alerts_topic_arn" {
  description = "ARN of the SNS topic every alarm and the AWS Budget publish to"
  value       = aws_sns_topic.alerts.arn
}

# Security Outputs
output "inspector2_findings_filter_name" {
  description = "AWS Inspector v2 filter surfacing CRITICAL/HIGH findings"
  value       = aws_inspector2_filter.critical_high.name
}

# Cost Management Outputs
output "budget_name" {
  description = "Name of the AWS Cost Budget"
  value       = aws_budgets_budget.monthly.name
}

output "monthly_budget_limit_usd" {
  description = "Monthly budget threshold in USD (see var.monthly_budget_limit for the cost breakdown behind it)"
  value       = var.monthly_budget_limit
}

output "billing_alarm_arn" {
  description = "ARN of the CloudWatch EstimatedCharges billing alarm"
  value       = aws_cloudwatch_metric_alarm.billing_estimated_charges.arn
}
