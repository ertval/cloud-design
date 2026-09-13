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
  description = "List of availability zones to distribute subnets across"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public tier subnets (ALB, NAT Gateway)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  description = "CIDR blocks for private application tier subnets (EKS/ECS compute)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "private_db_subnet_cidrs" {
  description = "CIDR blocks for private database tier subnets (RDS, Amazon MQ)"
  type        = list(string)
  default     = ["10.0.20.0/24", "10.0.21.0/24"]
}

variable "single_nat_gateway" {
  description = "Set to true to deploy a single NAT Gateway across AZs to minimize non-production costs"
  type        = bool
  default     = false
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
  description = "RabbitMQ broker engine version"
  type        = string
  default     = "3.13"
}

variable "mq_host_instance_type" {
  description = "Amazon MQ broker instance type"
  type        = string
  default     = "mq.t3.micro"
}

variable "mq_user" {
  description = "Administrative username for Amazon MQ broker"
  type        = string
  default     = "rabbit_admin"
}

# ------------------------------------------------------------------------------
# Orchestration (EKS / ECS)
# ------------------------------------------------------------------------------
variable "eks_cluster_version" {
  description = "Kubernetes control plane version for Amazon EKS"
  type        = string
  default     = "1.30"
}

variable "eks_node_instance_types" {
  description = "EC2 instance types for EKS managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "eks_min_size" {
  description = "Minimum node count in EKS node group"
  type        = number
  default     = 2
}

variable "eks_max_size" {
  description = "Maximum node count in EKS node group"
  type        = number
  default     = 5
}

variable "eks_desired_size" {
  description = "Desired node count in EKS node group"
  type        = number
  default     = 2
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
  description = "Optional notification email for CloudWatch critical alarms"
  type        = string
  default     = "cloud-ops@example.com"
}

variable "monthly_budget_limit" {
  description = "Monthly budget spend limit in USD for AWS Budgets and CloudWatch billing alerts"
  type        = number
  default     = 15
}

variable "allowed_origins" {
  description = "CORS allowed origins for API Gateway (replace placeholder with real app domain)"
  type        = list(string)
  default     = ["https://app.example.com"]
}
