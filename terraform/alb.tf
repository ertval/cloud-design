# ------------------------------------------------------------------------------
# Application Load Balancer (ALB) with HTTPS, ACM Certificate, & Target Groups
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# TLS certificate: two mutually exclusive paths
#
# A. enable_acm_certificate = true  (production)
#    Requests a real AWS-issued certificate validated over DNS, and publishes an
#    alias record pointing at the ALB. This is the only path that satisfies the
#    project requirement "secure API endpoints with AWS Certificate Manager", and
#    the only one that lets the Cognito hosted-UI OAuth redirect complete,
#    because browsers reject certificates they cannot chain to a public trust
#    root. That same redirect is what the ALB's authenticate-cognito action
#    depends on (below), so path A is also what makes the ALB login work at all.
#    Requires you to already own alb_domain_name in Route 53 (alb_hosted_zone_id).
#
# B. enable_acm_certificate = false (default - fresh account / first apply)
#    Self-signed certificate, so `terraform apply` always succeeds with no DNS
#    prerequisite. THE TRADE-OFF, stated plainly: browsers and most HTTP clients
#    will warn and refuse to trust the ALB. NOTE: the API Gateway VPC Link hop is
#    NOT affected - an HTTP_PROXY/VPC_LINK integration has no documented
#    client-side certificate-chain validation against the ALB listener, so the
#    API Gateway path works on either path. Switch to path A for anything that is
#    actually demonstrated to an auditor through a browser.
# ------------------------------------------------------------------------------

# --- Path A: AWS-issued, DNS-validated -----------------------------------------
resource "aws_acm_certificate" "alb" {
  count = var.enable_acm_certificate ? 1 : 0

  domain_name       = var.alb_domain_name
  validation_method = "DNS"

  # ACM Private CA is AWS-internal only; ALB needs a publicly trusted chain.
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

# Public DNS name for the ALB.
resource "aws_route53_record" "alb" {
  count = var.enable_acm_certificate ? 1 : 0

  zone_id = var.alb_hosted_zone_id
  name    = var.alb_domain_name
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

# --- Path B: self-signed fallback ---------------------------------------------
resource "tls_private_key" "alb" {
  count = var.enable_acm_certificate ? 0 : 1

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "alb" {
  count = var.enable_acm_certificate ? 0 : 1

  private_key_pem = tls_private_key.alb[0].private_key_pem

  subject {
    common_name  = "api.cloud-design.local"
    organization = "Cloud-Design Microservices"
  }

  validity_period_hours = 8760 # 1 year

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "alb_self_signed" {
  count = var.enable_acm_certificate ? 0 : 1

  private_key      = tls_private_key.alb[0].private_key_pem
  certificate_body = tls_self_signed_cert.alb[0].cert_pem

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-alb-acm-cert-self-signed"
  })
}

# The single certificate ARN the listener terminates with, whichever path ran.
# try() rather than a ternary. A `cond ? list[0] : list[0]` does NOT work here:
# Terraform evaluates both conditional branches (the untaken one is discarded, but
# only after evaluation), so the `aws_acm_certificate.alb_self_signed[0].arn` side
# raises "invalid index" whenever count = 0 - i.e. on every apply that uses the
# ACM path, which is exactly the path that must work. try() short-circuits instead
# and lands on whichever list actually has count > 0.
locals {
  alb_certificate_arn = try(aws_acm_certificate.alb[0].arn, aws_acm_certificate.alb_self_signed[0].arn)
  alb_base_url        = var.enable_acm_certificate ? "https://${var.alb_domain_name}" : "https://${aws_lb.main.dns_name}"
}

# 2. Application Load Balancer in Public Subnets
resource "aws_lb" "main" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false
  drop_invalid_header_fields = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-alb"
    Tier = "Public-ALB"
  })
}

# 3. Target Group for API Gateway Service (Port 3000)
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

# 3b. Target Group for billing-app (Port 8080)
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

# ------------------------------------------------------------------------------
# Security model of the :443 listener (FIX 5)
# ------------------------------------------------------------------------------
# The listener used to have a single `default_action` that forwarded EVERY path
# straight to api-gateway with no authenticator, while the SG admitted the world
# on :443. That is an unauthenticated WRITE path: `POST /api/billing` reached the
# application with no token, the gateway published the payload to RabbitMQ and the
# order landed in the billing database. (Both docs calling this "only GET is
# reachable" were wrong - the api-gateway proxy route accepts POST /api/billing.)
#
# The default action is now a two-step action list:
#   1. authenticate-cognito against the SAME user pool (on_unauthenticated_request
#      = "deny", so an Internet client with no Cognito session gets 401 and the
#      write path is closed), then
#   2. forward to api-gateway.
# authenticate-cognito is only supported on HTTPS listeners, which is why it is
# here and not on the :80 redirect listener. It needs the public (no client
# secret) app client and the hosted-UI domain - the /oauth2/idpresponse callback
# it redirects to is registered on aws_cognito_user_pool_client.main in
# cognito.tf.
#
# THE ONE EXCEPTION, stated honestly: API Gateway's own HTTP_PROXY/VPC_LINK hop
# also terminates on this listener, and it authenticates with a JWT at the
# ROUTE level (aws_apigatewayv2_route) - a bearer token the ALB cannot use,
# because ALB Cognito auth reads the `aws-cognito-identity-token` session cookie,
# not the Authorization header. Forcing Cognito on that hop would 401 every
# request and take the entire documented API down. So traffic originating inside
# the VPC is matched by the source-ip rules below and forwarded without a second
# authentication step, and everything from outside must present a Cognito
# session. The residual trade-off: an ENI inside this VPC can reach the ALB on
# :443 and be forwarded. Closing that too would mean making the ALB internal and
# making API Gateway the only public entry, which would also remove the public
# ACM endpoint this design uses.
# ------------------------------------------------------------------------------
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.alb_certificate_arn

  default_action {
    type = "authenticate-cognito"

    authenticate_cognito {
      user_pool_arn       = aws_cognito_user_pool.main.arn
      user_pool_client_id = aws_cognito_user_pool_client.main.id
      user_pool_domain    = aws_cognito_user_pool_domain.main.domain
      # deny, not authenticate: a browser should get the hosted-UI redirect, but a
      # token-less API/CLI call must get a hard 401 instead of a 303 to a login
      # page. Nothing is forwarded without a session either way.
      on_unauthenticated_request = "deny"
      session_timeout            = 3600
    }
  }

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.apigw.arn
  }

  tags = local.common_tags
}

# 5. HTTP Listener (Port 80) with Automatic HTTPS Redirection
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = local.common_tags
}

# 6. HTTPS Listener Rules
# NOTE: :80 listener is redirect-only (see above). All path-based forwarding
# lives on :443 so plaintext HTTP can never bypass TLS. /health is served by the
# target groups' health checks and, from inside the VPC, by the VPC Link hop
# below - there is no public unauthenticated /health rule on the listener any more,
# because the default action now requires a Cognito session.
#
# Priority matters: the listener evaluates rules in ascending priority order and
# falls back to the default action (Cognito) only when none match. Both rules
# below are scoped to var.vpc_cidr, which is the API Gateway VPC Link ENIs (they
# live in the private app subnets), so they do NOT re-open the unauthenticated
# Internet path - they only cover the internal hop.
resource "aws_lb_listener_rule" "billing_orders" {
  listener_arn = aws_lb_listener.https.arn
  # 1, not 10: this rule must be evaluated before the catch-all vpc_link_hop below,
  # which would otherwise forward /api/billing/orders to api-gateway (which has no
  # such route) and 404.
  priority = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.billing.arn
  }

  condition {
    path_pattern {
      values = ["/api/billing/orders", "/api/billing/orders/*"]
    }
  }

  condition {
    source_ip {
      values = [var.vpc_cidr]
    }
  }
}

# The API Gateway -> ALB hop (HTTP_PROXY over VPC_LINK, api_gateway.tf). Matched on
# source IP rather than path so it also carries the unauthenticated GET /health
# route and both billing route shapes without duplicating path patterns.
resource "aws_lb_listener_rule" "vpc_link_hop" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.apigw.arn
  }

  condition {
    source_ip {
      values = [var.vpc_cidr]
    }
  }
}
