# ------------------------------------------------------------------------------
# AWS Inspector v2: Continuous Vulnerability Scanning
# ------------------------------------------------------------------------------
# The audit checklist requires "regularly scanning for vulnerabilities with AWS
# Inspector" and the previous revision of this project had zero coverage here.
#
# SCOPE: ECR only. The container images are the entire software attack surface of
# this stack (no EC2 instances are created - compute is ECS Fargate), so scanning
# ECR gives complete coverage for the lowest cost. Adding "EC2" to
# resource_types below enables instance scanning too, at a per-host charge.
#
# NOTE ON THE PROVIDER VERSION: `aws_inspector2_enumerator` (with its
# `scan_on_create` argument) only exists from AWS provider v6.x onwards. This
# project is pinned to provider 5.100.0 (see .terraform.lock.hcl), where the
# supported resources are `aws_inspector2_enabler` + `aws_inspector2_filter`.
# Scan-on-push for ECR is therefore configured on the repositories themselves
# (`image_scanning_configuration.scan_on_push` in ecr.tf).
# ------------------------------------------------------------------------------

resource "aws_inspector2_enabler" "main" {
  account_ids    = [local.account_id]
  resource_types = ["ECR"]
}

# Surface CRITICAL and HIGH findings for triage.
# `action = "NONE"` deliberately does NOT suppress them: a suppressed finding is
# hidden from the dashboard, which is the opposite of what an audit wants. The
# "DEACTIVATE + tag findings" action (`action_criteria`) is not exposed by
# aws_inspector2_filter in provider 5.100.0 - only NONE and SUPPRESS exist.
resource "aws_inspector2_filter" "critical_high" {
  name        = "${local.name_prefix}-critical-high"
  description = "CRITICAL and HIGH severity findings across the account's ECR images"
  action      = "NONE"
  reason      = "Triage queue for the security review; findings are reported, never suppressed."

  filter_criteria {
    severity {
      comparison = "EQUALS"
      value      = "CRITICAL"
    }

    severity {
      comparison = "EQUALS"
      value      = "HIGH"
    }
  }

  tags = local.common_tags
}
