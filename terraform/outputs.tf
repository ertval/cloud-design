# ------------------------------------------------------------------------------
# Terraform Outputs
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

# Entrypoint / Gateway Outputs
output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "alb_arn" {
  description = "ARN of the Application Load Balancer"
  value       = aws_lb.main.arn
}

output "api_gateway_invoke_url" {
  description = "HTTPS invoke URL for the Amazon API Gateway"
  value       = aws_apigatewayv2_api.main.api_endpoint
}

# Authentication Outputs (AWS Cognito)
output "cognito_user_pool_id" {
  description = "AWS Cognito User Pool ID"
  value       = aws_cognito_user_pool.main.id
}

output "cognito_user_pool_client_id" {
  description = "AWS Cognito User Pool Client ID"
  value       = aws_cognito_user_pool_client.main.id
}

output "cognito_issuer_url" {
  description = "Cognito Token Issuer URL"
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

# Messaging Outputs (Amazon MQ)
output "amazon_mq_broker_id" {
  description = "Amazon MQ RabbitMQ Broker ID"
  value       = aws_mq_broker.rabbitmq.id
}

output "amazon_mq_endpoints" {
  description = "Amazon MQ RabbitMQ Broker AMQP/Management endpoints"
  value       = try(aws_mq_broker.rabbitmq.instances[0].endpoints, [])
}

# Orchestration Outputs
output "eks_cluster_name" {
  description = "Amazon EKS Cluster Name"
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  description = "Kubernetes API Server Endpoint for Amazon EKS"
  value       = aws_eks_cluster.main.endpoint
}

output "eks_cluster_certificate_authority" {
  description = "Base64 encoded certificate data required to communicate with the EKS cluster"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "ecs_cluster_name" {
  description = "Amazon ECS Cluster Name"
  value       = aws_ecs_cluster.main.name
}

# Observability Outputs
output "cloudwatch_dashboard_name" {
  description = "Name of the CloudWatch centralized operational dashboard"
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}

# Cost Management Outputs
output "budget_name" {
  description = "Name of the AWS Cost Budget"
  value       = aws_budgets_budget.monthly.name
}

output "billing_alarm_arn" {
  description = "ARN of the CloudWatch EstimatedCharges billing alarm"
  value       = aws_cloudwatch_metric_alarm.billing_estimated_charges.arn
}
