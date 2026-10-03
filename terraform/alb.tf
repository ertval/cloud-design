# ------------------------------------------------------------------------------
# Application Load Balancer (ALB) with HTTPS, ACM Certificate, & Target Groups
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# TLS certificate: two mutually exclusive paths
#
# A. enable_acm_certificate = true  (production)
#    Requests a real AWS-issued certificate validated over DNS, and publishes an
#    alias record pointing at the ALB. This is the only path that satisfies the
#    project requirement "secure API endpoints with AWS Certificate Manager" and
#    the only one that lets a Cognito hosted-UI OAuth redirect complete, because
#    browsers reject certificates they cannot chain to a public trust root.
#    Requires you to already own alb_domain_name in Route 53 (alb_hosted_zone_id).
#
# B. enable_acm_certificate = false (default - fresh account / first apply)
#    Self-signed certificate, so `terraform apply` always succeeds with no DNS
#    prerequisite. THE TRADE-OFF, stated plainly: browsers and most HTTP clients
#    will warn, and the API Gateway VPC Link integration in api_gateway.tf
#    validates the ALB certificate chain, so the private ALB integration path is
#    the part most likely to need path A. Switch to path A for anything that is
#    actually demonstrated to an auditor.
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
# try() rather than a ternary: a `cond ? list[0] : list[0]` indexes the list that
# does not exist on the untaken branch. Only one of the two lists has count > 0,
# so try() always lands on the right one.
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

# 4. HTTPS Listener (Port 443) with Modern TLS Policy
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.alb_certificate_arn

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

# 6. HTTPS Listener Rule: Forward API traffic to Target Group
# NOTE: :80 listener is redirect-only (see above). All path-based forwarding
# lives on :443 so plaintext HTTP can never bypass TLS. /health is served only
# via target-group health checks, not via a public listener rule.
resource "aws_lb_listener_rule" "api_traffic" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.apigw.arn
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }
}
