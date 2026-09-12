# ------------------------------------------------------------------------------
# AWS Cognito: Managed Authentication (User Pool & App Client)
# ------------------------------------------------------------------------------

resource "random_string" "cognito_domain_suffix" {
  length  = 8
  special = false
  upper   = false
}

# 1. Cognito User Pool with Enterprise Password Policy
resource "aws_cognito_user_pool" "main" {
  name = "${local.name_prefix}-user-pool"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "Cloud-Design: Your Verification Code"
    email_message        = "Your verification code for Cloud-Design is {####}."
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  tags = local.common_tags
}

# 2. Cognito User Pool Domain for Hosted Auth UI & Token Endpoints
resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${var.project_name}-auth-${random_string.cognito_domain_suffix.result}"
  user_pool_id = aws_cognito_user_pool.main.id
}

# 3. Cognito User Pool App Client
resource "aws_cognito_user_pool_client" "main" {
  name         = "${local.name_prefix}-client"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code", "implicit"]
  allowed_oauth_scopes                 = ["email", "openid", "profile"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = ["https://localhost:3000/callback", "https://api.cloud-design.local/callback"]
  logout_urls   = ["https://localhost:3000/logout"]

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_ADMIN_USER_PASSWORD_AUTH"
  ]

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  access_token_validity         = 1
  id_token_validity             = 1
  refresh_token_validity        = 30
  prevent_user_existence_errors = "ENABLED"
}
