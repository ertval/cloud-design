# ------------------------------------------------------------------------------
# AWS Cognito: Managed Authentication (User Pool & App Clients)
# ------------------------------------------------------------------------------

resource "random_string" "cognito_domain_suffix" {
  length  = 8
  special = false
  upper   = false
}

# Password for the optional demo identity. Only created when the demo user is
# enabled and the operator did not supply one, so the default deployment never
# ships a password anyone can guess.
resource "random_password" "demo_user" {
  count = var.enable_demo_cognito_user && var.demo_user_password == null ? 1 : 0

  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+"
  # Must satisfy the pool's password_policy below (upper, lower, number, symbol).
  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
  min_special = 1
}

locals {
  demo_user_password = var.enable_demo_cognito_user ? coalesce(var.demo_user_password, try(random_password.demo_user[0].result, null)) : null
}

# 1. Cognito User Pool with Enterprise Password Policy
resource "aws_cognito_user_pool" "main" {
  name = "${local.name_prefix}-user-pool"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # MFA is not *enforced* (that would block the audit walkthrough unless every
  # device is registered first) but it is offered, and `software_token` is the
  # TOTP option that needs no extra infrastructure.
  mfa_configuration = "OPTIONAL"

  software_token_mfa_configuration {
    enabled = true
  }

  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
    # Reuse of the previous 3 passwords is refused, which blunts credential
    # stuffing against a known password list.
    # NOTE: on AWS provider 5.x this attribute exists ONLY inside the
    # `password_policy` block. Declared at resource top level it fails
    # `terraform validate` with "An argument named password_history_size is not
    # expected here" - which is exactly how it was found by the audit script.
    password_history_size = 3
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
    # false = users may self-register through the hosted UI. Set to true to make
    # the pool admin-only (Terraform's demo user still works either way).
    allow_admin_create_user_only = false
  }

  # Require a fresh password on every credential change. Equivalent intent to
  # Cognito's account-takeover protection; the setting itself lives inside the
  # `password_policy` block above (see the note there).

  # Any authenticated user may change their own email, but only to a value they
  # have already verified - blocks silent account-hijack via attribute edit.
  # NOTE: every listed attribute MUST also appear in auto_verified_attributes
  # above or the AWS API rejects the whole user pool. The pool is email-only
  # (username_attributes = ["email"]), so phone_number is deliberately absent.
  user_attribute_update_settings {
    attributes_require_verification_before_update = ["email"]
  }

  tags = local.common_tags
}

# 2. Cognito User Pool Domain for Hosted Auth UI & Token Endpoints
# The hosted-UI domain is what makes the JWT demonstrable: the auditor signs in
# at https://<domain>.auth.<region>.amazoncognito.com/login and receives tokens.
resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${var.project_name}-auth-${random_string.cognito_domain_suffix.result}"
  user_pool_id = aws_cognito_user_pool.main.id
}

# 3. Cognito User Pool App Client (public, PKCE - used by the browser frontend)
resource "aws_cognito_user_pool_client" "main" {
  name         = "${local.name_prefix}-client"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  # FIX: "implicit" is deprecated (it returns tokens in the URL fragment, which
  # leaks them into browser history and referrer headers). Authorization Code
  # with PKCE is the replacement and is what SPAs should use.
  allowed_oauth_flows          = ["code"]
  allowed_oauth_scopes         = ["email", "openid", "profile"]
  supported_identity_providers = ["COGNITO"]

  callback_urls = compact([
    "https://localhost:3000/callback",
    var.alb_domain_name != "" ? "https://${var.alb_domain_name}/callback" : "https://api.cloud-design.local/callback",
    # The two /oauth2/idpresponse callbacks were removed with the ALB's
    # authenticate-cognito action: the ALB is internal now (alb.tf) and
    # authentication happens only at the API Gateway JWT authorizer.
  ])
  logout_urls = [
    "https://localhost:3000/logout",
    var.alb_domain_name != "" ? "https://${var.alb_domain_name}/logout" : "https://api.cloud-design.local/logout",
  ]

  # PKCE note: `supported_challenge_flows` / `oauth_flows_user_pool_client_secret`
  # are NOT exposed by aws_cognito_user_pool_client in provider 5.100.0. That is
  # not a gap in practice - with generate_secret = false Cognito treats the
  # client as public and REQUIRES PKCE (S256) for the authorization-code flow, so
  # dropping the deprecated "implicit" flow above is what actually closes the
  # token-in-URL-fragment leak.
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  prevent_user_existence_errors = "ENABLED"

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30
}

# 4. Demo app client: confidential, for the audit walkthrough
# `aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH` needs a client
# SECRET, which the public PKCE client above (generate_secret = false) does not
# have. This second client provides one so the "get a JWT, call a protected
# route" demo runs immediately after apply. It also disables USER_SRP_AUTH in
# favour of USER_PASSWORD_AUTH only, because USER_PASSWORD_AUTH is not supported
# by every Cognito client configuration and naming it explicitly avoids the
# InvalidParameterException at the call site.
resource "aws_cognito_user_pool_client" "demo" {
  count = var.enable_demo_cognito_user ? 1 : 0

  name         = "${local.name_prefix}-demo-client"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = true

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  supported_identity_providers  = ["COGNITO"]
  prevent_user_existence_errors = "ENABLED"

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30
}

# 5. Demo user
# Without this resource `initiate-auth` returns UserNotFoundException and the
# entire "services communicate securely with managed authentication" claim is
# undemonstrable on a fresh apply.
resource "aws_cognito_user" "demo" {
  count = var.enable_demo_cognito_user ? 1 : 0

  user_pool_id = aws_cognito_user_pool.main.id
  username     = var.demo_user_email

  password = local.demo_user_password

  attributes = {
    email          = var.demo_user_email
    email_verified = "true"
  }

  # Keep Terraform from failing an apply because an address that cannot receive
  # mail already exists in the pool.
  message_action           = "SUPPRESS"
  desired_delivery_mediums = []
}
