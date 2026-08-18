###############################################################################
# Amazon Managed Grafana (AMG)
#
# Workspace authenticated via IAM Identity Center, querying AMP + CloudWatch
# through a customer-managed role (var.grafana_role_arn). A Grafana service account
# + token are minted so the grafana provider can manage datasources and dashboards
# as code. All gated by enable_observability.
###############################################################################

resource "aws_grafana_workspace" "this" {
  count                    = var.enable_observability ? 1 : 0
  name                     = "${var.name_prefix}-grafana"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "CUSTOMER_MANAGED"
  role_arn                 = var.grafana_role_arn
  data_sources             = ["PROMETHEUS", "CLOUDWATCH"]
}

# Grant ADMIN to the configured Identity Center user. Empty id -> assign users in the console.
resource "aws_grafana_role_association" "admin" {
  count        = var.enable_observability && var.grafana_admin_user_id != "" ? 1 : 0
  workspace_id = aws_grafana_workspace.this[0].id
  role         = "ADMIN"
  user_ids     = [var.grafana_admin_user_id]
}

# Service account + token used only by the grafana provider to provision datasources
# and dashboards. seconds_to_live is the 30-day max; if a later apply fails Grafana
# auth, recreate this token (terraform apply -replace=...service_account_token.tf[0]).
resource "aws_grafana_workspace_service_account" "tf" {
  count        = var.enable_observability ? 1 : 0
  name         = "terraform-provisioner"
  grafana_role = "ADMIN"
  workspace_id = aws_grafana_workspace.this[0].id
}

resource "aws_grafana_workspace_service_account_token" "tf" {
  count              = var.enable_observability ? 1 : 0
  name               = "terraform-provisioner-token"
  service_account_id = aws_grafana_workspace_service_account.tf[0].service_account_id
  seconds_to_live    = 2592000
  workspace_id       = aws_grafana_workspace.this[0].id
}
