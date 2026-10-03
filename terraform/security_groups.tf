# ------------------------------------------------------------------------------
# Least-Privilege Security Groups with Standalone Rules to Avoid Dependency Cycles
# ------------------------------------------------------------------------------
# The EKS control-plane security group and its three rules were removed with the
# EKS path (see orchestration.tf). No private resource is reachable from outside
# the VPC: only the ALB SG accepts 0.0.0.0/0, and only on 80 (redirect) / 443.
# ------------------------------------------------------------------------------

# 1. Public ALB Security Group (Internet-facing entrypoint)
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Allows incoming public HTTP/HTTPS traffic to Application Load Balancer"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-alb-sg"
    Tier = "Public-ALB"
  })
}

resource "aws_security_group_rule" "alb_ingress_http" {
  description = "HTTP ingress (redirected to HTTPS)"
  type        = "ingress"
  from_port   = 80
  to_port     = 80
  protocol    = "tcp"
  # JUSTIFICATION: public ALB must accept Internet clients; :80 serves
  # redirect-to-:443 only (see alb.tf), no plaintext forwarding.
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "alb_ingress_https" {
  description = "HTTPS ingress for secure client traffic"
  type        = "ingress"
  from_port   = 443
  to_port     = 443
  protocol    = "tcp"
  # JUSTIFICATION: public edge-TLS entrypoint; TLS 1.3 terminated at ALB.
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "alb_egress_to_app" {
  description              = "Forward traffic to the api-gateway container on port 3000"
  type                     = "egress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.alb.id
}

# FIX (was missing entirely): API Gateway integrates with the ALB over the VPC
# Link, and that integration targets the *HTTPS* listener (aws_lb_listener.https,
# referenced by api_gateway.tf). Without this rule the VPC Link ENIs could not
# reach :443 and every single API Gateway route returned HTTP 500.
resource "aws_security_group_rule" "alb_ingress_from_vpc_link" {
  description              = "Accept API Gateway VPC Link traffic on the HTTPS listener"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.vpc_link.id
  security_group_id        = aws_security_group.alb.id
}

# 2. Private App Security Group (ECS Fargate tasks)
resource "aws_security_group" "app" {
  name        = "${local.name_prefix}-app-sg"
  description = "Restricted security group for ECS Fargate microservice tasks in private subnets"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-app-sg"
    Tier = "Private-App"
  })
}

# Inbound from ALB on port 3000
resource "aws_security_group_rule" "app_ingress_from_alb" {
  description              = "Allow inbound HTTP from ALB to API Gateway service"
  type                     = "ingress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.app.id
}

# Internal service-to-service communication on port 8080 (inventory and billing)
resource "aws_security_group_rule" "app_ingress_internal_service" {
  description       = "Allow internal service-to-service communication on port 8080"
  type              = "ingress"
  from_port         = 8080
  to_port           = 8080
  protocol          = "tcp"
  self              = true
  security_group_id = aws_security_group.app.id
}

# Task-to-task communication on any port (Cloud Map / intra-service fan-out)
resource "aws_security_group_rule" "app_ingress_self" {
  description       = "Allow tasks to communicate with each other"
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.app.id
}

# Outbound to Database Tier (PostgreSQL 5432)
resource "aws_security_group_rule" "app_egress_to_db" {
  description              = "Allow outbound connection to RDS PostgreSQL database tier"
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.db.id
  security_group_id        = aws_security_group.app.id
}

# Outbound to Amazon MQ on AMQPS 5671.
# FIX: the previous revision documented "TLS callers use 5671" and opened the
# 5671 ingress rule on the broker, but never opened a matching egress rule here,
# so AMQPS was unreachable no matter what the client did. Note that Amazon MQ for
# RabbitMQ ONLY listens on 5671 (AMQPS) - there is no plaintext 5672 listener -
# so 5671 is the one correct port for both producer (api-gateway) and consumer
# (billing-app) traffic.
resource "aws_security_group_rule" "app_egress_to_mq_amqps" {
  description              = "Allow outbound AMQPS (TLS) connection to the Amazon MQ RabbitMQ broker"
  type                     = "egress"
  from_port                = 5671
  to_port                  = 5671
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.mq.id
  security_group_id        = aws_security_group.app.id
}

# Outbound to the RabbitMQ management console (15671, TLS) for operational checks
resource "aws_security_group_rule" "app_egress_to_mq_management" {
  description              = "Allow outbound HTTPS to the RabbitMQ management console"
  type                     = "egress"
  from_port                = 15671
  to_port                  = 15671
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.mq.id
  security_group_id        = aws_security_group.app.id
}

# Outbound HTTPS for AWS APIs (ECR, CloudWatch, Secrets Manager, etc.) via NAT Gateway
resource "aws_security_group_rule" "app_egress_https" {
  description = "Allow outbound HTTPS for container registries and AWS service endpoints"
  type        = "egress"
  from_port   = 443
  to_port     = 443
  protocol    = "tcp"
  # JUSTIFICATION: tasks must reach public AWS service endpoints (ECR,
  # CloudWatch, Secrets Manager, Cognito) via NAT; no VPC endpoints deployed.
  # Restricted to 443/tcp; DNS separately scoped to VPC CIDR below.
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.app.id
}

# Outbound DNS (UDP and TCP)
resource "aws_security_group_rule" "app_egress_dns_udp" {
  description       = "Allow internal DNS UDP resolution"
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.app.id
}

resource "aws_security_group_rule" "app_egress_dns_tcp" {
  description       = "Allow internal DNS TCP resolution"
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.app.id
}

# 3. Private Database Security Group (RDS PostgreSQL)
# ACCESSIBLE ONLY FROM WITHIN THE VPC BY COMPUTE NODES
resource "aws_security_group" "db" {
  name        = "${local.name_prefix}-db-sg"
  description = "Strict least-privilege security group for PostgreSQL databases - internal access only"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-db-sg"
    Tier = "Private-DB"
  })
}

resource "aws_security_group_rule" "db_ingress_from_app" {
  description              = "Allow PostgreSQL access exclusively from private app compute tier"
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.db.id
}

# 4. Private Amazon MQ RabbitMQ Security Group
# ACCESSIBLE ONLY FROM WITHIN THE VPC BY COMPUTE NODES
resource "aws_security_group" "mq" {
  name        = "${local.name_prefix}-mq-sg"
  description = "Strict least-privilege security group for RabbitMQ broker - internal access only"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-mq-sg"
    Tier = "Private-MQ"
  })
}

# Amazon MQ for RabbitMQ supports AMQP over TLS (5671) only - it has no
# plaintext listener and no mutual-TLS/mTLS option. Both producer and consumer
# traffic therefore uses 5671, which satisfies the "encryption in transit"
# requirement instead of merely tolerating its absence.
resource "aws_security_group_rule" "mq_ingress_amqps" {
  description              = "Allow AMQPS (TLS) broker communication from the private app tier"
  type                     = "ingress"
  from_port                = 5671
  to_port                  = 5671
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.mq.id
}

resource "aws_security_group_rule" "mq_ingress_management" {
  description = "Allow RabbitMQ Web Management console access (TLS) from the private app tier"
  type        = "ingress"
  from_port   = 15671
  to_port     = 15671
  protocol    = "tcp"
  # FIX: RabbitMQ brokers on Amazon MQ serve the management UI on 15671 with TLS,
  # not the self-hosted default 15672.
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.mq.id
}
