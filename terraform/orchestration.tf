# ------------------------------------------------------------------------------
# Container Orchestration: Amazon EKS & Amazon ECS
# ------------------------------------------------------------------------------

# KMS Key for EKS Secrets Encryption at rest
resource "aws_kms_key" "eks_secrets" {
  description             = "KMS Customer Managed Key for EKS cluster envelope encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-eks-secrets-kms"
  })
}

# 1. Amazon EKS Cluster (Control Plane)
resource "aws_eks_cluster" "main" {
  name     = "${local.name_prefix}-eks"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.eks_cluster_version

  vpc_config {
    subnet_ids              = aws_subnet.private_app[*].id
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_private_access = true
    # Private-only API: admins reach the cluster via bastion/VPN in the VPC.
    # To allow restricted public admin, set true + public_access_cidrs = [<admin range>].
    endpoint_public_access = false
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks_secrets.arn
    }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller,
    aws_cloudwatch_log_group.eks_cluster
  ]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-eks"
  })
}

# 2. EKS Managed Node Group (Compute Worker Nodes in Private Subnets)
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.name_prefix}-worker-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = aws_subnet.private_app[*].id

  scaling_config {
    desired_size = var.eks_desired_size
    max_size     = var.eks_max_size
    min_size     = var.eks_min_size
  }

  instance_types = var.eks_node_instance_types
  capacity_type  = "ON_DEMAND"

  update_config {
    max_unavailable = 1
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-eks-node"
  })

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_read_only,
  ]
}

# 3. OpenID Connect (OIDC) Provider for EKS IAM Roles for Service Accounts (IRSA)
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks_oidc" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = local.common_tags
}

# 4. Amazon ECS Cluster (Alternative serverless Fargate execution mode)
resource "aws_ecs_cluster" "main" {
  name = "${local.name_prefix}-ecs-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ecs-cluster"
  })
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}
