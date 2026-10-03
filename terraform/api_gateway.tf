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
    # Restricted via var.allowed_origins (default app domain placeholder);
    # do not revert to ["*"] in production (credentialed JWT + browsers).
    allow_origins = var.allowed_origins
    max_age       = 3600
  }

  tags = local.common_tags
}

locals {
  # `aud` semantics for an API Gateway HTTP API JWT authorizer: the token's `aud`
  # claim must equal one of the strings in `audience`, and `iss` must match
  # `issuer`. It is NOT an OAuth "resource server" list - Cognito stamps the
  # audience with the ID of the APP CLIENT that minted the token, never with the
  # API Gateway id or the user pool id. So the audience has to enumerate every
  # app client whose tokens are meant to work here:
  #   * aws_cognito_user_pool_client.main  - the public PKCE client the browser
  #     frontend authenticates with.
  #   * aws_cognito_user_pool_client.demo - the confidential client behind the
  #     audit walkthrough (`initiate-auth ... USER_PASSWORD_AUTH`). It is behind
  #     `count`, so it may not exist at all.
  # FIX: this used to list ONLY main.id, so a token minted through the documented
  # demo flow carried `aud = <demo client id>` and the authorizer answered 401 for
  # the exact login flow the docs tell an auditor to perform.
  # `demo[*].id` is the counted-resource splat: it yields a one-element list when
  # count = 1 and an EMPTY list when count = 0, so the concat below stays valid
  # with no `[0]` index to be guarded.
  jwt_audiences = concat(
    [aws_cognito_user_pool_client.main.id],
    aws_cognito_user_pool_client.demo[*].id,
  )
}

# 2. Cognito JWT Authorizer
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.main.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "${local.name_prefix}-cognito-jwt-authorizer"

  jwt_configuration {
    audience = local.jwt_audiences
    issuer   = "https://${aws_cognito_user_pool.main.endpoint}"
  }
}

# 3. VPC Link for Private Integration to ALB
# NOTE ON RULE DIRECTION: AWS IGNORES inbound rules on a VPC Link security group
# (the API Gateway-managed ENIs have no IP that a rule could usefully reference)
# but egress IS enforced, so the only rules that matter here are the egress ones.
resource "aws_security_group" "vpc_link" {
  name        = "${local.name_prefix}-vpc-link-sg"
  description = "Security group for API Gateway VPC Link"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "Allow outbound to ALB listener HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow outbound to ALB listener HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # FIX (was missing): the VPC Link ENIs resolve the ALB and, for any AWS-owned
  # endpoint name, AmazonProvidedDNS - which is a VPC resolver reachable only on
  # 53. Mirrors aws_security_group_rule.app_egress_dns_udp/_tcp in
  # security_groups.tf; without both of these the API Gateway -> ALB hop can fail
  # to resolve and every route returns 5xx.
  egress {
    description = "Allow DNS over UDP to AmazonProvidedDNS"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow DNS over TCP to AmazonProvidedDNS"
    from_port   = 53
    to_port     = 53
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

# 4. HTTP Proxy Integration Forwarding to ALB (via HTTPS listener only;
# never the :80 redirect listener, so VPC_LINK traffic stays TLS-terminated)
resource "aws_apigatewayv2_integration" "alb" {
  api_id             = aws_apigatewayv2_api.main.id
  integration_type   = "HTTP_PROXY"
  integration_uri    = aws_lb_listener.https.arn
  integration_method = "ANY"
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.alb.id

  payload_format_version = "1.0"
}

# 5. Public Healthcheck Route (Unauthenticated for external uptime monitors)
# Reaches api-gateway through the ALB rule aws_lb_listener_rule.vpc_link_hop,
# which is scoped to the VPC CIDR because the source here is a VPC Link ENI, not
# an Internet client - so leaving it unauthenticated does not expose /health on
# the public listener (there the Cognito action in alb.tf returns 401).
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
# POST /api/billing lands on api-gateway, which publishes to RabbitMQ (srcs/
# api-gateway/app/proxy.py). GET /api/billing/orders has to reach billing-app
# itself, and since srcs/ is owned by another team the routing is done here: the
# ALB splits the two paths with aws_lb_listener_rule.billing_orders, so no
# BILLING_APP_HOST/PORT env pair or extra proxy route is needed in the app.
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
