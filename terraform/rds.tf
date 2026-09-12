# ------------------------------------------------------------------------------
# Amazon RDS PostgreSQL Databases (Inventory and Billing)
# ------------------------------------------------------------------------------

# Random passwords for databases
resource "random_password" "inventory_db" {
  length           = 20
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "billing_db" {
  length           = 20
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# KMS Key for Database Storage Encryption
resource "aws_kms_key" "rds" {
  description             = "KMS Key for RDS PostgreSQL storage encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rds-kms"
  })
}

# 1. AWS Secrets Manager: Inventory Database Credentials
resource "aws_secretsmanager_secret" "inventory_db" {
  name                    = "${local.name_prefix}-inventory-db-credentials"
  kms_key_id              = aws_kms_key.rds.arn
  recovery_window_in_days = 0

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "inventory_db" {
  secret_id = aws_secretsmanager_secret.inventory_db.id
  secret_string = jsonencode({
    engine   = "postgres"
    host     = aws_db_instance.inventory.address
    port     = aws_db_instance.inventory.port
    username = var.db_username
    password = random_password.inventory_db.result
    database = "inventory_db"
  })
}

# 2. AWS Secrets Manager: Billing Database Credentials
resource "aws_secretsmanager_secret" "billing_db" {
  name                    = "${local.name_prefix}-billing-db-credentials"
  kms_key_id              = aws_kms_key.rds.arn
  recovery_window_in_days = 0

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "billing_db" {
  secret_id = aws_secretsmanager_secret.billing_db.id
  secret_string = jsonencode({
    engine   = "postgres"
    host     = aws_db_instance.billing.address
    port     = aws_db_instance.billing.port
    username = var.db_username
    password = random_password.billing_db.result
    database = "billing_db"
  })
}

# ------------------------------------------------------------------------------
# RDS PostgreSQL Instance: Inventory Database (movies)
# ------------------------------------------------------------------------------
resource "aws_db_instance" "inventory" {
  identifier            = "${local.name_prefix}-inventory-db"
  engine                = "postgres"
  engine_version        = "16.3"
  instance_class        = var.db_instance_class
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds.arn

  db_name  = "inventory_db"
  username = var.db_username
  password = random_password.inventory_db.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  multi_az                    = var.environment == "prod" ? true : false
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false
  backup_retention_period     = 7
  backup_window               = "03:00-04:00"
  maintenance_window          = "Mon:04:30-Mon:05:30"
  skip_final_snapshot         = true
  deletion_protection         = false

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-inventory-db"
    Tier = "Private-DB"
  })
}

# ------------------------------------------------------------------------------
# RDS PostgreSQL Instance: Billing Database (orders)
# ------------------------------------------------------------------------------
resource "aws_db_instance" "billing" {
  identifier            = "${local.name_prefix}-billing-db"
  engine                = "postgres"
  engine_version        = "16.3"
  instance_class        = var.db_instance_class
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds.arn

  db_name  = "billing_db"
  username = var.db_username
  password = random_password.billing_db.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  multi_az                    = var.environment == "prod" ? true : false
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false
  backup_retention_period     = 7
  backup_window               = "04:00-05:00"
  maintenance_window          = "Tue:05:30-Tue:06:30"
  skip_final_snapshot         = true
  deletion_protection         = false

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-billing-db"
    Tier = "Private-DB"
  })
}
