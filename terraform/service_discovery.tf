# ------------------------------------------------------------------------------
# Cloud Map Service Discovery: Private DNS for East-West Traffic
# ------------------------------------------------------------------------------
# WHY CLOUD MAP AND NOT PER-SERVICE ALB TARGET GROUPS
# The architecture has exactly one internet-facing ALB, which fronts api-gateway
# only (the ALB target group in alb.tf). inventory-app and billing-app are
# private and must still be reachable by name, so they get their own mechanism:
# a Cloud Map private DNS namespace. Each ECS service registers its tasks, and
# AmazonProvidedDNS answers `inventory-app.<namespace>` with the healthy task
# IPs. api-gateway then resolves INVENTORY_APP_HOST through normal VPC DNS.
#
# MECHANISM (one, implemented fully end to end):
#   namespace -> aws_service_discovery_service.<app> -> A record, MULTIVALUE
#   -> aws_ecs_service.<app>.service_registries -> ECS health-check demotion
# ------------------------------------------------------------------------------

locals {
  # Cloud Map service name == the DNS label the calling container resolves. The
  # "inventory-app" key MUST match the INVENTORY_APP_HOST value injected into
  # the api-gateway task definition in ecs_services.tf.
  # (RABBITMQ_HOST is NOT a Cloud Map name: the broker is an Amazon MQ managed
  # instance with its own AWS-assigned hostname - see amazon_mq.tf.)
  service_discovery_services = {
    api-gateway   = 3000
    inventory-app = 8080
    billing-app   = 8080
  }
}

resource "aws_service_discovery_private_dns_namespace" "main" {
  # `.local` is the suffix AWS documents for private namespaces; it is only ever
  # resolved by AmazonProvidedDNS inside this VPC, never on the internet.
  name        = "${local.name_prefix}.local"
  description = "Private DNS namespace for ${local.name_prefix} microservices"
  vpc         = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-cloud-map"
  })
}

resource "aws_service_discovery_service" "app" {
  for_each = local.service_discovery_services

  name        = each.key
  description = "Cloud Map service for ${each.key} (:${each.value})"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    # MULTIVALUE returns every healthy task IP in a single answer, so callers
    # fail over across tasks (and across AZs) without a headless proxy.
    routing_policy = "MULTIVALUE"
  }

  # ECS-managed health checking: a task whose container health check fails is
  # removed from the DNS answer after failure_threshold x 30s, which is what
  # makes this discovery layer HA-aware rather than purely round-robin.
  health_check_custom_config {
    failure_threshold = 1
  }

  tags = local.common_tags
}
