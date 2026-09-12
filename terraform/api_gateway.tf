# ------------------------------------------------------------------------------
# Amazon API Gateway (HTTP API v2) with Cognito JWT Authorizer
# ------------------------------------------------------------------------------

# 1. API Gateway HTTP API
resource "aws_apigatewayv2_api" "main" {
  name          = "${local.name_prefix}-api"
  protocol_type = "HTTP"
  description   = "Cloud-Design API Gateway entrypoint forwarding requests to Application Load Balancer"

  cors_configuration {
    allow_headers = ["authorization", "content-type", "x-amz-date", "x-api-key"]
    allow_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    allow_origins = ["*"]
    max_age       = 3600
  }

  tags = local.common_tags
}

# 2. Cognito JWT Authorizer
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.main.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "${local.name_prefix}-cognito-jwt-authorizer"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.main.id]
    issuer   = "https://${aws_cognito_user_pool.main.endpoint}"
  }
}

# 3. VPC Link for Private Integration to ALB
resource "aws_security_group" "vpc_link" {
  name        = "${local.name_prefix}-vpc-link-sg"
  description = "Security group for API Gateway VPC Link"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "Allow outbound to ALB listener"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = local.common_tags
}

resource "aws_apigatewayv2_vpc_link" "alb" {
  name               = "${local.name_prefix}-alb-vpc-link"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = aws_subnet.private_app[*].id

  tags = local.common_tags
}

# 4. HTTP Proxy Integration Forwarding to ALB
resource "aws_apigatewayv2_integration" "alb" {
  api_id             = aws_apigatewayv2_api.main.id
  integration_type   = "HTTP_PROXY"
  integration_uri    = aws_lb_listener.http.arn
  integration_method = "ANY"
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.alb.id

  payload_format_version = "1.0"
}

# 5. Public Healthcheck Route (Unauthenticated for external uptime monitors)
resource "aws_apigatewayv2_route" "health" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /health"
  target    = "integrations/${aws_apigatewayv2_integration.alb.id}"
}

# 6. Protected Movies Routes (Cognito Authorization Required)
resource "aws_apigatewayv2_route" "movies" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "ANY /api/movies"
  target             = "integrations/${aws_apigatewayv2_integration.alb.id}"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
  authorization_type = "JWT"
}

resource "aws_apigatewayv2_route" "movies_proxy" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "ANY /api/movies/{proxy+}"
  target             = "integrations/${aws_apigatewayv2_integration.alb.id}"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
  authorization_type = "JWT"
}

# 7. Protected Billing Routes (Cognito Authorization Required)
resource "aws_apigatewayv2_route" "billing" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "ANY /api/billing"
  target             = "integrations/${aws_apigatewayv2_integration.alb.id}"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
  authorization_type = "JWT"
}

resource "aws_apigatewayv2_route" "billing_proxy" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "ANY /api/billing/{proxy+}"
  target             = "integrations/${aws_apigatewayv2_integration.alb.id}"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
  authorization_type = "JWT"
}

# 8. API Gateway Stage with CloudWatch Access Logging and Rate Limiting
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn
    format = jsonencode({
      requestId               = "$context.requestId"
      sourceIp                = "$context.identity.sourceIp"
      requestTime             = "$context.requestTime"
      httpMethod              = "$context.httpMethod"
      routeKey                = "$context.routeKey"
      status                  = "$context.status"
      protocol                = "$context.protocol"
      responseLength          = "$context.responseLength"
      authorizerPrincipalId   = "$context.authorizer.principalId"
      integrationErrorMessage = "$context.integrationErrorMessage"
    })
  }

  default_route_settings {
    throttling_burst_limit = 5000
    throttling_rate_limit  = 2500
  }

  tags = local.common_tags
}
