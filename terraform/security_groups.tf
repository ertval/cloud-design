# ------------------------------------------------------------------------------
# Least-Privilege Security Groups with Standalone Rules to Avoid Dependency Cycles
# ------------------------------------------------------------------------------
# The EKS control-plane security group and its three rules were removed with the
# EKS path (see orchestration.tf). No resource is reachable from outside the
# VPC: no security group accepts 0.0.0.0/0 ingress. The only public entry point
# is API Gateway, which is AWS-managed and reaches the internal ALB through the
# VPC Link (alb.tf).
#
# TASK-TO-TASK IS 8080 ONLY, AND ONLY WITHIN THE APP SG. Every one of api-gateway,
# inventory-app and billing-app shares aws_security_group.app, so a rule opened
# with `self = true` is reachable by ALL THREE services - which is exactly why
# :8080 is the only port opened: the app SG egress below also lets every task
# reach db:5432 and mq:5671, so an all-ports self rule would hand a compromised
# billing-app task a lateral-movement path to the inventory database and the
# broker using its own credentials.
# ------------------------------------------------------------------------------

# 1. Internal ALB Security Group (reached only through the API Gateway VPC Link)
# FIX: this group used to admit 0.0.0.0/0 on :80 and :443 because the ALB was
# internet-facing. The ALB is internal now (alb.tf), and its one ingress rule is
# alb_ingress_from_vpc_link below.
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Internal ALB: accepts traffic only from the API Gateway VPC Link"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-alb-sg"
    Tier = "Private-ALB"
  })
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

# Second target group (alb.tf: aws_lb_target_group.billing) exposes
# GET /api/billing/orders, which billing-app serves on :8080, so the ALB needs a
# matching egress path. Without it the rule exists but every request 502s.
resource "aws_security_group_rule" "alb_egress_to_billing_app" {
  description              = "Forward traffic to the billing-app container on port 8080"
  type                     = "egress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.alb.id
}

# The ALB's only ingress rule. API Gateway integrates with the ALB over the VPC
# Link, on the port of aws_lb_listener.main (80, or 443 when
# enable_acm_certificate = true). Without this rule the VPC Link ENIs could not
# reach the listener and every API Gateway route would return HTTP 500.
resource "aws_security_group_rule" "alb_ingress_from_vpc_link" {
  description              = "Accept API Gateway VPC Link traffic on the ALB listener"
  type                     = "ingress"
  from_port                = local.alb_listener_port
  to_port                  = local.alb_listener_port
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

# Inbound from ALB on port 3000 (api-gateway, the ALB target group in alb.tf)
resource "aws_security_group_rule" "app_ingress_from_alb" {
  description              = "Allow inbound HTTP from ALB to API Gateway service"
  type                     = "ingress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.app.id
}

# Inbound from ALB on port 8080 (billing-app target group, see alb.tf). Only the
# billing service listens on :8080 behind the ALB; inventory-app is reached over
# Cloud Map, not the ALB.
resource "aws_security_group_rule" "app_ingress_from_alb_billing" {
  description              = "Allow inbound HTTP from ALB to billing-app service on 8080"
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.app.id
}

# Task-to-task on :8080 (api-gateway -> inventory-app). FIX: this used to be
# `protocol = "-1", from_port = 0, to_port = 0`, which is ALL ports on ALL
# protocols, self-referenced. Because all three services share this SG it also
# opened billing-app -> db:5432 and billing-app -> mq:5671, and every task in the
# tier already holds working credentials for both. It also subsumed the separate
# 8080 ingress rule (app_ingress_internal_service), which has therefore been
# deleted rather than left as a duplicate. Narrowed to tcp/8080.
resource "aws_security_group_rule" "app_ingress_self" {
  description       = "Allow task-to-task service calls on port 8080 only"
  type              = "ingress"
  from_port         = 8080
  to_port           = 8080
  protocol          = "tcp"
  self              = true
  security_group_id = aws_security_group.app.id
}

# The egress half of the same :8080 call. FIX (was completely missing): security
# groups are STATEFUL, so the 8080 ingress rule above only covers the RETURN
# traffic of a connection a task itself opened. The initiating side still needs
# egress, or the connection is dropped before it is ever made - which is why
# GET/POST/PUT/DELETE /api/movies through API Gateway -> ALB -> api-gateway ->
# inventory-app returned 502 on every call even though the ingress rule existed.
resource "aws_security_group_rule" "app_egress_internal_service" {
  description       = "Allow tasks to OPEN connections to sibling tasks on :8080 (Cloud Map)"
  type              = "egress"
  from_port         = 8080
  to_port           = 8080
  protocol          = "tcp"
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
