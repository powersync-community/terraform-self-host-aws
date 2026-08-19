output "config_secret_arn" {
  description = "Full ARN (with suffix), for reference only. Task defs use the prefix ARN from locals."
  value       = aws_secretsmanager_secret.config.arn
}

output "config_secret_name" {
  value = aws_secretsmanager_secret.config.name
}

output "cwagent_param_name" {
  value = aws_ssm_parameter.cwagent.name
}
