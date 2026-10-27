# ------------------------------------------------------------------------------
# Internal Application Load Balancer, reached only through the API Gateway VPC Link
# ------------------------------------------------------------------------------
# API Gateway is the only public entry point. Its public endpoint is HTTPS with
# an AWS-managed certificate, and it authenticates every /api/* route with the
# Cognito JWT authorizer (api_gateway.tf). It reaches this ALB over a VPC Link,
# and the ALB splits the traffic between the api-gateway and billing-app target
# groups.
#
# FIX: the ALB used to be internet-facing, with a Cognito login action on :443,
# a :80 redirect and two source-IP rules that let the VPC Link through. That was
# two public entry points and two auth layers, and the login action could not
# work: ALB Cognito authentication requires an app client WITH a client secret,
# and it used the public PKCE client (generate_secret = false). The VPC Link hop
# was broken too: API Gateway sends plain HTTP unless the integration has a
# tls_config, so every request reached the :443 listener as HTTP.
#
# TLS on the VPC Link hop: two paths, chosen by var.enable_acm_certificate.
#
# A. false (default, no domain needed): HTTP listener on :80. The hop never
#    leaves the VPC and only the VPC Link security group can reach the listener
#    (security_groups.tf). This is the cost choice: a domain and a hosted zone
#    are the only things path B needs that path A does not.
#
# B. true: HTTPS listener on :443 with an AWS-issued ACM certificate, DNS
#    validated in a Route 53 zone you already own (alb_domain_name +
#    alb_hosted_zone_id). The integration's tls_config makes API Gateway verify
#    that certificate against alb_domain_name. API Gateway HTTP APIs cannot skip
#    that verification, which is why a self-signed certificate is no longer an
#    option here.
# ------------------------------------------------------------------------------

resource "aws_acm_certificate" "alb" {
  count = var.enable_acm_certificate ? 1 : 0

  domain_name       = var.alb_domain_name
  validation_method = "DNS"

  # ACM Private CA is AWS-internal only; API Gateway needs a publicly trusted chain.
  options {
    certificate_transparency_logging_preference = "ENABLED"
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-alb-acm-cert"
  })

  # Allows ACM to renew the certificate without a forced replacement of the
  # listener that is currently using it.
  lifecycle {
    create_before_destroy = true
  }
}

# DNS-01 challenge records. ACM does not create these for you.
# for_each only (never count alongside it - Terraform rejects the combination);
# the empty map when disabled means zero records are managed.
resource "aws_route53_record" "acm_validation" {
  for_each = var.enable_acm_certificate ? {
    for option in aws_acm_certificate.alb[0].domain_validation_options :
    option.domain_name => {
      name   = option.resource_record_name
      record = option.resource_record_value
      type   = option.resource_record_type
    }
  } : {}

  zone_id         = var.alb_hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "alb" {
  count = var.enable_acm_certificate ? 1 : 0

  certificate_arn         = aws_acm_certificate.alb[0].arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]
}

locals {
  alb_listener_port     = var.enable_acm_certificate ? 443 : 80
  alb_listener_protocol = var.enable_acm_certificate ? "HTTPS" : "HTTP"
}

# 1. Internal Application Load Balancer in the private app subnets
resource "aws_lb" "main" {
  name               = "${local.name_prefix}-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.private_app[*].id

  enable_deletion_protection = false
  drop_invalid_header_fields = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-alb"
    Tier = "Private-ALB"
  })
}

# 2. Target Group for API Gateway Service (Port 3000)
resource "aws_lb_target_group" "apigw" {
  name        = "${local.name_prefix}-apigw-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    port                = "3000"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-apigw-tg"
  })
}

# 2b. Target Group for billing-app (Port 8080)
# WHY A SECOND TARGET GROUP: billing-app serves GET /api/billing/orders
# (srcs/billing-app/app/__init__.py) but nothing called it - the api-gateway proxy
# only forwards /api/movies* and POST /api/billing (which it turns into a RabbitMQ
# publish). srcs/ belongs to another team and api-gateway has no BILLING_APP_HOST
# env pair, so instead of an application change the read path is routed here: a
# second ALB target group plus one listener rule (aws_lb_listener_rule
# .billing_orders) is pure Terraform and needs no code change. The
# corresponding SG egress is aws_security_group_rule.alb_egress_to_billing_app.
resource "aws_lb_target_group" "billing" {
  name        = "${local.name_prefix}-billing-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    port                = "8080"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-billing-tg"
  })
}

# 3. The single listener: HTTP :80 by default, HTTPS :443 with ACM (path B above)
# Every request on it has already passed the Cognito JWT authorizer in API
# Gateway, except the public GET /health route. Only the VPC Link security group
# can reach it (security_groups.tf), so there is no unauthenticated path from
# the internet to the ALB.
resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = local.alb_listener_port
  protocol          = local.alb_listener_protocol
  # Both are null on the HTTP path. one() turns the empty list that count = 0
  # leaves behind into null, so no [0] index has to be guarded. The validation
  # resource, not the certificate, is referenced so the listener waits until
  # ACM has actually issued the certificate.
  ssl_policy      = var.enable_acm_certificate ? "ELBSecurityPolicy-TLS13-1-2-2021-06" : null
  certificate_arn = one(aws_acm_certificate_validation.alb[*].certificate_arn)

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.apigw.arn
  }

  tags = local.common_tags
}

# 4. Listener rule: /api/billing/orders (billing-app's read path) goes to
# billing-app; everything else falls through to the default action, api-gateway.
resource "aws_lb_listener_rule" "billing_orders" {
  listener_arn = aws_lb_listener.main.arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.billing.arn
  }

  condition {
    path_pattern {
      values = ["/api/billing/orders", "/api/billing/orders/*"]
    }
  }
}
