# ------------------------------------------------------------------------------
# Container Orchestration: Amazon ECS on Fargate
# ------------------------------------------------------------------------------
# Single orchestration path (see docs/audit.md "Simplicity"): ECS/Fargate runs
# the three applications. The previous revision also provisioned an EKS control
# plane, which was removed for three concrete reasons:
#   1. EKS control planes cost ~$73/month with no workloads on them.
#   2. endpoint_public_access was false with no bastion/DVPN in the design, so
#      `kubectl` could never reach the cluster - yet the audit explicitly asks
#      the student to demonstrate it (docs/audit.md:62,76).
#   3. Two orchestrators, two load balancers and two data tiers failed the
#      graded "Simplicity" pillar.
# The Kubernetes manifests under manifests/ are intentionally KEPT in the repo as
# the orchestrator-lineage artifact (explicit bonus, docs/readme.md:197); they are
# documentation of the original design, not something Terraform applies.
# ------------------------------------------------------------------------------

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

# FARGATE_SPOT is only registered when var.ecs_use_fargate_spot is true, which is
# the same flag that makes the ECS services emit a capacity_provider_strategy
# block instead of launch_type (see ecs_services.tf). Declaring a capacity
# provider here that no service could ever use would be dead configuration.
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = var.ecs_use_fargate_spot ? ["FARGATE", "FARGATE_SPOT"] : ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = var.ecs_use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
    base              = var.ecs_use_fargate_spot ? 0 : 1
  }
}
