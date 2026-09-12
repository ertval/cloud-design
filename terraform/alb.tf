# ------------------------------------------------------------------------------
# Application Load Balancer (ALB) with HTTPS, ACM Certificate, & Target Groups
# ------------------------------------------------------------------------------

# 1. TLS Private Key & Self-Signed Certificate for ACM
# (Allows instantaneous TLS 1.3 HTTPS deployment without external DNS dependencies)
resource "tls_private_key" "alb" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "alb" {
  private_key_pem = tls_private_key.alb.private_key_pem

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

resource "aws_acm_certificate" "alb" {
  private_key      = tls_private_key.alb.private_key_pem
  certificate_body = tls_self_signed_cert.alb.cert_pem

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-alb-acm-cert"
  })
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
  certificate_arn   = aws_acm_certificate.alb.arn

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
