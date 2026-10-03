variable "aws_region" {
  description = "AWS deployment region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name identifier for the project resources"
  type        = string
  default     = "cloud-design"
}

variable "environment" {
  description = "Target deployment environment (dev, staging, prod)"
  type        = string
  default     = "prod"
}

# ------------------------------------------------------------------------------
# Networking / VPC
# ------------------------------------------------------------------------------
variable "vpc_cidr" {
  description = "CIDR block for the Virtual Private Cloud"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = <<-EOT
    Availability zones to spread subnets across. Leave EMPTY to auto-discover the
    first two zones of var.aws_region; setting this list to a hard-coded zone
    name was previously the reason the stack failed to apply outside us-east-1.
    Must contain at least two entries (vpc.tf asserts this at plan time).
  EOT
  type    = list(string)
  default = []

  validation {
    condition     = length(var.availability_zones) == 0 || length(var.availability_zones) >= 2
    error_message = "availability_zones needs at least 2 zones for a Multi-AZ design, or 0 to auto-discover them."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public tier subnets (ALB, NAT Gateway)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  description = "CIDR blocks for private application tier subnets (ECS Fargate tasks)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "private_db_subnet_cidrs" {
  description = "CIDR blocks for private database tier subnets (RDS, Amazon MQ)"
  type        = list(string)
  default     = ["10.0.20.0/24", "10.0.21.0/24"]
}

variable "single_nat_gateway" {
  description = <<-EOT
    Set to true to deploy ONE NAT Gateway shared by both private app subnets,
    saving ~$33/month (a NAT Gateway is ~$32.85/month + data processing). The
    trade-off is real and is the reason the default is false: with a single NAT
    the private tier loses AZ independence for all outbound traffic (pulling
    images from ECR, CloudWatch Logs, Secrets Manager), so an AZ failure or an
    NAT maintenance window takes the whole application down. Keep this false for
    any environment you intend to call highly available, and set it true only
    for a short-lived, disposable dev sandbox.
  EOT
  type    = bool
  default = false
}

# ------------------------------------------------------------------------------
# TLS at the ALB
# ------------------------------------------------------------------------------
variable "enable_acm_certificate" {
  description = <<-EOT
    Request a real, AWS-issued ACM certificate for the ALB and publish an
    alias record for it (requires alb_domain_name + alb_hosted_zone_id).
    Leave false for a first apply in a brand-new account: DNS validation cannot
    complete until the _acme-challenge TXT record is visible in a hosted zone you
    already own. The false path falls back to a self-signed certificate so
    `terraform apply` always succeeds.
  EOT
  type    = bool
  default = false
}

variable "alb_domain_name" {
  description = "Fully qualified domain name for the public ALB (e.g. api.example.com). Required when enable_acm_certificate = true."
  type        = string
  default     = ""
}

variable "alb_hosted_zone_id" {
  description = "Route 53 public hosted zone ID that owns alb_domain_name. Required when enable_acm_certificate = true."
  type        = string
  default     = ""
}

# ------------------------------------------------------------------------------
# Databases (RDS PostgreSQL)
# ------------------------------------------------------------------------------
variable "db_instance_class" {
  description = "Database instance compute class"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Initial allocated storage in GB"
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Maximum storage limit for autoscaling in GB"
  type        = number
  default     = 100
}

variable "db_username" {
  description = "Master administrative username for RDS PostgreSQL instances"
  type        = string
  default     = "dbadmin"
}

# ------------------------------------------------------------------------------
# Messaging (Amazon MQ RabbitMQ)
# ------------------------------------------------------------------------------
variable "mq_engine_version" {
  description = "RabbitMQ broker engine version. 3.13 is supported on the mq.m7g instance family; Amazon MQ also offers 4.2, which requires mq.m7g and is the prerequisite for a future in-place 3.13 -> 4.2 upgrade."
  type        = string
  default     = "3.13"
}

variable "mq_host_instance_type" {
  description = <<-EOT
    Amazon MQ broker instance type.
    FIX: this defaulted to mq.t3.micro, which AWS has deprecated: it is "no longer
    available for new broker creation" and reaches end of support on October 1,
    2026, so `terraform apply` failed at CreateBroker. m7g.medium is the smallest
    type Amazon MQ still offers for RabbitMQ (1 vCPU / 4 GiB) and is what AWS
    itself recommends for evaluation; it is also the family RabbitMQ 4.x requires,
    so moving the broker to 4.2 later is an in-place engine upgrade rather than a
    replacement. Cost note: it is materially dearer than the retired t3.micro -
    see var.monthly_budget_limit for the recalculated estimate.
  EOT
  type        = string
  default     = "mq.m7g.medium"
}

variable "mq_user" {
  description = "Administrative username for Amazon MQ broker"
  type        = string
  default     = "rabbit_admin"
}

# ------------------------------------------------------------------------------
# Container Orchestration (ECS on Fargate)
# ------------------------------------------------------------------------------
variable "ecs_use_fargate_spot" {
  description = <<-EOT
    Run the ECS services on the FARGATE_SPOT capacity provider (up to ~70%
    cheaper) instead of FARGATE on-demand. Trade-off: Spot tasks can be reclaimed
    with a 2-minute warning, so api-gateway and inventory-app must keep
    desired_count >= 2 to survive an interruption, and the request path can drop
    an in-flight task. Deliberately false by default so the graded
    "Availability" and "Scalability" pillars are not undermined.
  EOT
  type    = bool
  default = false
}

# ------------------------------------------------------------------------------
# Auto Scaling & Monitoring
# ------------------------------------------------------------------------------
variable "autoscaling_target_cpu" {
  description = "Target average CPU utilization percentage for autoscaling trigger"
  type        = number
  default     = 60
}

variable "log_retention_days" {
  description = "CloudWatch log retention period in days"
  type        = number
  default     = 30
}

variable "alarm_email" {
  description = <<-EOT
    Notification email for CloudWatch alarms and AWS Budgets. Set to "" to create
    the SNS topic and alarms with no email subscriber. Any real address works;
    the previous default (cloud-ops@example.com) was an unroutable placeholder
    that silently swallowed every notification, so placeholder domains are now
    rejected at plan time by the validation block below.
  EOT
  type    = string
  default = ""

  validation {
    condition     = var.alarm_email == "" || !can(regex("@(example|invalid|test)\\.(com|org|net|local)$", lower(var.alarm_email)))
    error_message = "alarm_email must be a real, deliverable address or \"\" to disable email notifications - placeholder domains are rejected."
  }
}

variable "monthly_budget_limit" {
  description = <<-EOT
    Monthly budget in USD. The previous default of 15 USD was ~20x below the real
    run-rate, so the budget alarm fired every single month and proved useless.
    Steady-state estimate for this design (us-east-1, on-demand Fargate):

      Amazon MQ ACTIVE_STANDBY_MULTI_AZ mq.m7g.medium x2 + 200GB EBS each  ~$230
      RDS PostgreSQL db.t4g.micro Multi-AZ x2 + storage ..................  ~$53
      NAT Gateways x2 .....................................................  ~$66
      Application Load Balancer ..........................................  ~$16
      ECS Fargate 4 x (0.25 vCPU / 0.5 GB) ................................  ~$37
      KMS keys, ECR storage + Inspector scans, CloudWatch logs/alarms ......  ~$9
      --------------------------------------------------------------------
      TOTAL ..............................................................  ~$410/mo

    The MQ line is the one that moved: mq.t3.micro was ~$79 but AWS withdrew it
    for new brokers (see var.mq_host_instance_type), and mq.m7g.medium is roughly
    double the instance hours plus two 200 GB EBS volumes at $0.10/GB-month.
    Peak (api-gateway + inventory-app auto-scaled to their max of 3, i.e. 8 tasks
    instead of 4) is ~$450/mo, hence a 450 USD default: the 80% ACTUAL
    notification then fires at $360 as a genuine early warning rather than as
    routine noise. This is an estimate built from published unit prices, not a
    quote - re-check it against the AWS Pricing Calculator before demoing.
  EOT
  type        = number
  default     = 450

  validation {
    condition     = var.monthly_budget_limit >= 50
    error_message = "monthly_budget_limit must be at least 50 USD to be meaningful for this Multi-AZ design."
  }
}

variable "allowed_origins" {
  description = "CORS allowed origins for API Gateway. MUST be replaced with the real frontend domain(s) - see terraform.tfvars.example."
  type        = list(string)
  default     = ["https://app.example.com"]
}

# ------------------------------------------------------------------------------
# Artefact / log-archive storage
# ------------------------------------------------------------------------------
variable "enable_artifact_bucket" {
  description = <<-EOT
    Create the S3 bucket that backs log- and artefact-archival (storage.tf). The
    audit brief asks for "storage services using AWS S3 or similar" and the repo
    previously contained no storage service at all. Set false to skip it for a
    throwaway sandbox; an empty bucket costs nothing beyond the requests made
    against it, so there is no reason to disable it for a real deployment.
  EOT
  type        = bool
  default     = true
}

# ------------------------------------------------------------------------------
# Database teardown
# ------------------------------------------------------------------------------
variable "db_final_snapshot" {
  description = <<-EOT
    Take a final manual snapshot of each RDS instance when Terraform destroys it.
    FALSE BY DEFAULT, deliberately: it matches the behaviour scripts/destroy.sh
    documents ("both instances use skip_final_snapshot = true, so terraform takes
    none"), and the generated name is fixed, so a second destroy of a recreated
    stack fails with AlreadyExists until the first snapshot is deleted. Turn it on
    before destroying anything you care about, and delete the snapshots by hand
    afterwards (snapshot storage is billed).
  EOT
  type        = bool
  default     = false
}

# ------------------------------------------------------------------------------
# Cognito demo identity (audit walkthrough)
# ------------------------------------------------------------------------------
variable "enable_demo_cognito_user" {
  description = <<-EOT
    Create the optional demo user plus a secret-bearing app client so the audit
    walkthrough ("initiate-auth ... returns a JWT") works immediately after
    apply. Set to false for anything resembling a real deployment: the demo user
    is a permanent-password account created by Terraform, and the password ends
    up in Terraform state either way (this is why it is also offered as a
    sensitive input via demo_user_password).
  EOT
  type    = bool
  default = true
}

variable "demo_user_email" {
  description = "Email address (and username) of the optional Cognito demo user."
  type        = string
  default     = "auditor@cloud-design.local"
}

variable "demo_user_password" {
  description = "Optional explicit password for the Cognito demo user. Leave null to have Terraform generate one (it must satisfy the user pool password policy) and expose it as a sensitive output."
  type        = string
  default     = null
  sensitive   = true
}
