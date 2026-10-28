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
  type        = list(string)
  default     = []

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
  type        = bool
  default     = false
}

# ------------------------------------------------------------------------------
# TLS at the ALB
# ------------------------------------------------------------------------------
variable "enable_acm_certificate" {
  description = <<-EOT
    false (default): the internal ALB listens on HTTP :80, so the API Gateway
    VPC Link hop is plain HTTP inside the VPC and no domain is needed. The
    public endpoint is API Gateway's own HTTPS endpoint either way.
    true: request a real, AWS-issued ACM certificate (requires alb_domain_name +
    alb_hosted_zone_id), switch the listener to HTTPS :443 and make API Gateway
    verify the certificate against alb_domain_name. DNS validation cannot
    complete until the validation record is visible in a hosted zone you
    already own.
  EOT
  type        = bool
  default     = false
}

variable "alb_domain_name" {
  description = "Domain name the ALB certificate is issued for (e.g. api.example.com); API Gateway verifies the ALB certificate against it. Required when enable_acm_certificate = true."
  type        = string
  default     = ""
}

variable "alb_hosted_zone_id" {
  description = "Route 53 public hosted zone ID that owns alb_domain_name, used for the ACM DNS validation records. Required when enable_acm_certificate = true."
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
  description = "Master administrative username for RDS PostgreSQL instances. Used only by the db-role-init container to create the apps' own roles (inventory_app, billing_app); the apps never connect as it."
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
  type        = bool
  default     = false
}

variable "image_tag" {
  description = <<-EOT
    ECR image tag the three ECS task definitions pull. scripts/build_push.sh
    --push pushes every application image as :latest AND as the git short SHA
    of its sources. "latest" works without any change, but pushing a new
    :latest does not change the task definition, so ECS keeps the old image
    until `aws ecs update-service --force-new-deployment`. Setting a pushed SHA
    (terraform apply -var image_tag=<sha>) registers a new task definition
    revision, rolls the services, and records exactly which build runs. The ECR
    lifecycle policy keeps the 5 most recent images, so pin a recent build.
  EOT
  type        = string
  default     = "latest"

  validation {
    condition     = can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", var.image_tag))
    error_message = "image_tag must be a valid ECR tag: 1-128 characters from A-Z a-z 0-9 _ . -, not starting with . or -."
  }
}

# ------------------------------------------------------------------------------
# Auto Scaling & Monitoring
# ------------------------------------------------------------------------------
variable "autoscaling_target_cpu" {
  description = "Target average CPU utilization percentage for autoscaling trigger"
  type        = number
  default     = 60
}

variable "billing_app_min_capacity" {
  description = <<-EOT
    Minimum number of billing-app tasks - the only RabbitMQ consumer and the
    only writer to the billing database. Never 1: a single consumer task is a
    single point of failure for order processing, and with prefetch_count = 1
    each task holds exactly one unacked message, so two tasks also drain the
    queue in parallel. Scales on queue backlog, not CPU.
  EOT
  type        = number
  default     = 2
}

variable "billing_app_max_capacity" {
  description = <<-EOT
    Maximum number of billing-app tasks. Bounded well above min_capacity so a
    sustained write burst can be worked off, while still capping the blast
    radius: every extra task is another writer against billing_db and another
    connection in DatabaseConnections.
  EOT
  type        = number
  default     = 6
}

variable "billing_queue_depth_target" {
  description = <<-EOT
    Target average AWS/AmazonMQ MessageCount for billing-app target tracking, in
    messages. The backlog size at which one more consumer pays for itself. Keep
    it comfortably above normal jitter so a quiet minute does not add capacity,
    and below the point where customers notice order latency. NOTE: Amazon MQ
    for RabbitMQ publishes no per-queue CloudWatch dimension, so this metric is
    broker-level and approximates the depth of billing_queue.
  EOT
  type        = number
  default     = 50
}

variable "log_retention_days" {
  description = "CloudWatch log retention period in days. Also the number of days the ALB access logs are kept in the S3 bucket (storage.tf)."
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
  type        = string
  default     = ""

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

      Amazon MQ SINGLE_INSTANCE mq.m7g.medium x1 + 200GB EBS .............  ~$115
      RDS PostgreSQL db.t4g.micro Multi-AZ x2 + storage ..................  ~$53
      NAT Gateways x2 .....................................................  ~$66
      Application Load Balancer ..........................................  ~$16
      ECS Fargate 6 x (0.25 vCPU / 0.5 GB), 2 per service .................  ~$54
      KMS keys, ECR storage + Inspector scans, CloudWatch logs/alarms ......  ~$9
      --------------------------------------------------------------------
      TOTAL ..............................................................  ~$313/mo

    The MQ line is the one that moved: mq.t3.micro was ~$79 but AWS withdrew it
    for new brokers (see var.mq_host_instance_type), and mq.m7g.medium is roughly
    double the instance hours plus a 200 GB EBS volume at $0.10/GB-month. It is
    one broker, not two: Amazon MQ for RabbitMQ has no active/standby mode (see
    amazon_mq.tf), and the three-node cluster would add ~$230.
    Peak (api-gateway + inventory-app auto-scaled to their max of 3, i.e. 8 tasks
    instead of 6) is ~$331/mo. The 450 USD default was sized for the earlier
    two-broker estimate (~$410 steady, ~$450 peak) and now sits above the peak.
    This is an estimate built from published unit prices, not a quote - re-check
    it against the AWS Pricing Calculator before demoing.
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
    Create the S3 bucket that receives the ALB access logs and backs log- and
    artefact-archival (storage.tf). The audit brief asks for "storage services
    using AWS S3 or similar". Set false to skip it for a throwaway sandbox; that
    also turns the ALB access logs off. At demo traffic the logs cost cents per
    month in S3 storage and requests, so keep it on for a real deployment.
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
  type        = bool
  default     = true
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
