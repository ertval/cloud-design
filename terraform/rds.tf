# ------------------------------------------------------------------------------
# Amazon RDS PostgreSQL Databases (Inventory and Billing)
# ------------------------------------------------------------------------------

# Random passwords for databases
# The "=" and ":" in override_special are fine HERE and are left alone on purpose:
# the broker's CreateBroker forbids , : = (amazon_mq.tf), but the RDS master
# password rule is a different and much narrower one - MasterUserPassword "can
# include any printable ASCII character except /, " or @". Regenerating these
# would rotate both databases' master passwords for no gain.
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

# ------------------------------------------------------------------------------
# Parameter group: encryption in transit
# ------------------------------------------------------------------------------
# family = postgres16 is unchanged by the engine-version bump below: RDS parameter
# group families are per MAJOR version, so 16.x keeps using postgres16 whatever
# minor is selected.
#
# The project requires data encrypted "at rest AND in transit"
# (docs/readme.md:98). Storage encryption covers "at rest"; this group covers
# "in transit" by refusing any non-TLS PostgreSQL session.
#
# rds.force_ssl = 1 makes the server reject plaintext connections outright, so a
# misconfigured client fails closed rather than silently downgrading.
#
# Client side: the apps build their DSN as
#   postgresql+psycopg2://user:pass@host:5432/db?sslmode=<DB_SSLMODE>
# and the ECS task definitions set DB_SSLMODE = "require" (ecs_services.tf),
# which is also the code default. So the requirement is explicit at both ends:
# the server refuses plaintext and the client never offers it. require
# encrypts but does not verify the server certificate; verify-full would also
# need the RDS CA bundle in the images.
resource "aws_db_parameter_group" "postgres" {
  name        = "${local.name_prefix}-postgres16-ssl"
  family      = "postgres16"
  description = "Enforces TLS for all PostgreSQL connections (rds.force_ssl)"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  tags = local.common_tags
}

# 1. AWS Secrets Manager: Inventory Database Credentials
# NOTE on recovery_window_in_days = 0 (unchanged, and deliberate): AWS's minimum
# non-zero window is 7 days, but a secret deleted WITH a recovery window is only
# SCHEDULED for deletion - it stays readable, and re-creating a secret with the
# same name then fails with ConflictException until the window elapses. That
# makes "destroy, change a variable, apply again" impossible on a same-named
# stack. 0 means the credential material dies with the stack.
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
  identifier = "${local.name_prefix}-inventory-db"
  engine     = "postgres"
  # FIX: was 16.3, a minor version RDS has since moved off - supported
  # PostgreSQL 16 minors now run from 16.9 up, and CreateDBInstance rejects the
  # retired ones. 16.9 is the oldest of the currently supported minors, which
  # leaves the most headroom before AWS auto-minor-upgrade has to move it again
  # (auto_minor_version_upgrade = true). The parameter group family stays
  # postgres16 because families are per MAJOR version.
  engine_version        = "16.9"
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
  parameter_group_name   = aws_db_parameter_group.postgres.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  # Always Multi-AZ: audit requires standby failover in all envs (cost
  # saving via single-AZ is not acceptable for this design).
  multi_az                    = true
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false
  backup_retention_period     = 7
  backup_window               = "03:00-04:00"
  maintenance_window          = "Mon:04:30-Mon:05:30"
  # Teardown behaviour is behind var.db_final_snapshot (default false) so that
  # `terraform destroy` keeps behaving exactly as scripts/destroy.sh documents it.
  # With it true, a snapshot named after this instance survives the destroy
  # instead of the data going with it - remember it is then billed until deleted.
  skip_final_snapshot       = !var.db_final_snapshot
  final_snapshot_identifier = var.db_final_snapshot ? "${local.name_prefix}-inventory-final" : null
  deletion_protection       = false

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-inventory-db"
    Tier = "Private-DB"
  })
}

# ------------------------------------------------------------------------------
# RDS PostgreSQL Instance: Billing Database (orders)
# ------------------------------------------------------------------------------
resource "aws_db_instance" "billing" {
  identifier = "${local.name_prefix}-billing-db"
  engine     = "postgres"
  # FIX: was 16.3, a minor version RDS has since moved off - supported
  # PostgreSQL 16 minors now run from 16.9 up, and CreateDBInstance rejects the
  # retired ones. 16.9 is the oldest of the currently supported minors, which
  # leaves the most headroom before AWS auto-minor-upgrade has to move it again
  # (auto_minor_version_upgrade = true). The parameter group family stays
  # postgres16 because families are per MAJOR version.
  engine_version        = "16.9"
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
  parameter_group_name   = aws_db_parameter_group.postgres.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  # Always Multi-AZ: audit requires standby failover in all envs (cost
  # saving via single-AZ is not acceptable for this design).
  multi_az                    = true
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false
  backup_retention_period     = 7
  backup_window               = "04:00-05:00"
  maintenance_window          = "Tue:05:30-Tue:06:30"
  # See the inventory instance above: the same var.db_final_snapshot gate.
  skip_final_snapshot       = !var.db_final_snapshot
  final_snapshot_identifier = var.db_final_snapshot ? "${local.name_prefix}-billing-final" : null
  deletion_protection       = false

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-billing-db"
    Tier = "Private-DB"
  })
}
