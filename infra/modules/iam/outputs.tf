output "execution_role_arn" {
  value = local.execution_role_arn
}

output "task_role_arn" {
  value = local.task_role_arn
}

output "events_role_arn" {
  value = local.events_role_arn
}

output "grafana_role_arn" {
  description = "Role AMG assumes to query AMP + CloudWatch (empty unless observability is enabled and roles are created here)."
  value       = local.create && var.enable_observability ? aws_iam_role.grafana[0].arn : ""
}

output "log_lambda_role_arn" {
  description = "Execution role for the CloudWatch-Logs->OpenSearch indexer Lambda (mapped to the OpenSearch write role)."
  value       = local.create && local.os ? aws_iam_role.log_lambda[0].arn : ""
}

output "alert_lambda_role_arn" {
  description = "Execution role for the SNS alert-logger Lambda."
  value       = local.create && var.enable_observability ? aws_iam_role.alert_lambda[0].arn : ""
}
