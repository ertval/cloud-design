# ------------------------------------------------------------------------------
# Least-Privilege Security Groups with Standalone Rules to Avoid Dependency Cycles
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
  description              = "Forward traffic exclusively to application compute nodes on port 3000"
  type                     = "egress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.alb.id
}

# 2. Private App / Compute Security Group (EKS Worker Nodes / ECS Tasks)
resource "aws_security_group" "app" {
  name        = "${local.name_prefix}-app-sg"
  description = "Restricted security group for microservices compute nodes in private subnets"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name                                             = "${local.name_prefix}-app-sg"
    Tier                                             = "Private-App"
    "kubernetes.io/cluster/${local.name_prefix}-eks" = "owned"
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

# Intra-cluster node-to-node communication
resource "aws_security_group_rule" "app_ingress_self" {
  description       = "Allow cluster nodes to communicate with each other"
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.app.id
}

# Inbound from EKS Control Plane
resource "aws_security_group_rule" "app_ingress_from_eks_cp" {
  description              = "Allow kubelet and webhook communication from EKS control plane"
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.eks_cluster.id
  security_group_id        = aws_security_group.app.id
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

# Outbound to Amazon MQ Tier (RabbitMQ AMQP 5672, plaintext inside VPC only;
# TLS callers use 5671; see mq_ingress_amqp comment below)
resource "aws_security_group_rule" "app_egress_to_mq" {
  description              = "Allow outbound connection to Amazon MQ RabbitMQ broker tier"
  type                     = "egress"
  from_port                = 5672
  to_port                  = 5672
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

# 3. EKS Control Plane Security Group
resource "aws_security_group" "eks_cluster" {
  name        = "${local.name_prefix}-eks-cluster-sg"
  description = "Communication between EKS control plane and worker nodes"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-eks-cluster-sg"
  })
}

resource "aws_security_group_rule" "eks_cluster_egress_all" {
  description = "Allow control plane to communicate with worker nodes"
  type        = "egress"
  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  # Tightened to VPC CIDR (was 0.0.0.0/0): control plane only needs kubelet/
  # webhook access to private nodes; all-protocols kept per AWS requirement
  # for ephemeral high ports.
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.eks_cluster.id
}

# Allow worker nodes to reach control plane on 443
resource "aws_security_group_rule" "eks_cluster_ingress_node_https" {
  description              = "Allow worker nodes to reach EKS control plane API server"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.eks_cluster.id
}

# 4. Private Database Security Group (RDS PostgreSQL / Containerized DB)
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

# 5. Private Amazon MQ RabbitMQ Security Group
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

resource "aws_security_group_rule" "mq_ingress_amqp" {
  description = "Allow AMQP broker communication exclusively from private app tier"
  type        = "ingress"
  from_port   = 5672
  to_port     = 5672
  protocol    = "tcp"
  # NOTE: 5672 is PLAINTEXT AMQP, restricted to app SG inside the VPC only.
  # TLS callers must use 5671 (AMQPS) below. No mTLS/service mesh yet (see README).
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.mq.id
}

resource "aws_security_group_rule" "mq_ingress_amqps" {
  description              = "Allow AMQPS SSL broker communication from private app tier"
  type                     = "ingress"
  from_port                = 5671
  to_port                  = 5671
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.mq.id
}

resource "aws_security_group_rule" "mq_ingress_management" {
  description              = "Allow RabbitMQ Web Management console access exclusively from private app tier"
  type                     = "ingress"
  from_port                = 15672
  to_port                  = 15672
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.mq.id
}
