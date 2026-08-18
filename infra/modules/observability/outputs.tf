output "amp_workspace_arn" {
  description = "ARN of the AMP workspace (empty string when observability is disabled). Scopes the task role's aps:RemoteWrite grant."
  value       = var.enable_observability ? aws_prometheus_workspace.this[0].arn : ""
}

output "amp_workspace_id" {
  value = var.enable_observability ? aws_prometheus_workspace.this[0].id : ""
}

# prometheus_endpoint already ends in a trailing slash (".../workspaces/ws-xxxx/"),
# so the remote-write path appends directly.
output "amp_remote_write_url" {
  description = "remote_write endpoint the ADOT sidecars push to (empty when disabled)."
  value       = var.enable_observability ? "${aws_prometheus_workspace.this[0].prometheus_endpoint}api/v1/remote_write" : ""
}

output "amp_query_url" {
  description = "Base AMP query endpoint (used by the Grafana AMP datasource)."
  value       = var.enable_observability ? aws_prometheus_workspace.this[0].prometheus_endpoint : ""
}

output "grafana_endpoint" {
  description = "AMG workspace endpoint host (no scheme)."
  value       = var.enable_observability ? aws_grafana_workspace.this[0].endpoint : ""
}

output "grafana_workspace_id" {
  value = var.enable_observability ? aws_grafana_workspace.this[0].id : ""
}

output "grafana_auth_token" {
  description = "Service-account token for the grafana provider to provision datasources/dashboards."
  value       = var.enable_observability ? aws_grafana_workspace_service_account_token.tf[0].key : ""
  sensitive   = true
}

output "opensearch_endpoint" {
  description = "OpenSearch domain endpoint host (no scheme)."
  value       = local.os_enabled ? aws_opensearch_domain.this[0].endpoint : ""
}

output "opensearch_dashboards_url" {
  description = "Native OpenSearch Dashboards URL."
  value       = local.os_enabled ? "https://${aws_opensearch_domain.this[0].endpoint}/_dashboards/" : ""
}

output "opensearch_arn" {
  value = local.os_enabled ? aws_opensearch_domain.this[0].arn : ""
}

output "log_lambda_arn" {
  description = "Log-indexer Lambda ARN; the ecs subscription filters target this."
  value       = local.os_enabled ? aws_lambda_function.log_indexer[0].arn : ""
}

output "log_lambda_function_name" {
  description = "Log-indexer Lambda name; used for the CloudWatch Logs invoke permission."
  value       = local.os_enabled ? aws_lambda_function.log_indexer[0].function_name : ""
}

output "alerts_sns_topic_arn" {
  description = "SNS topic all alerts publish to; the alert Lambda subscribes and forwards to the configured destination."
  value       = var.enable_observability ? aws_sns_topic.alerts[0].arn : ""
}

output "alert_logger_log_group" {
  description = "CloudWatch log group where fired alerts are recorded as JSON."
  value       = var.enable_observability ? aws_cloudwatch_log_group.alert_logger[0].name : ""
}

output "opensearch_master_user" {
  value = local.os_enabled ? var.name_prefix : ""
}

output "opensearch_master_password" {
  description = "Generated OpenSearch master-user password (Dashboards login)."
  value       = local.os_enabled ? random_password.opensearch_master[0].result : ""
  sensitive   = true
}
