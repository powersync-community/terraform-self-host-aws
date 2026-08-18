output "alb_dns" {
  description = "ALB DNS name (the Route 53 alias points the deployment domain here)."
  value       = module.alb.alb_dns
}

output "domain_url" {
  description = "Public HTTPS URL of the PowerSync API (the client endpoint)."
  value       = "https://${local.domain}"
}

output "certificate_arn" {
  value = module.alb.certificate_arn
}

output "cluster_name" {
  value = module.ecs.cluster_name
}

output "api_service_name" {
  value = module.ecs.api_service_name
}

output "replication_service_name" {
  value = module.ecs.replication_service_name
}

output "compact_task_family" {
  value = module.ecs.compact_task_family
}

output "log_group_names" {
  value = module.ecs.log_group_names
}

output "config_secret_arn" {
  description = "Full ARN of the config secret (task defs reference it by prefix)."
  value       = module.secrets.config_secret_arn
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "aws_region" {
  description = "Region everything is deployed in (used by example-client for the EC2/Secrets clients)."
  value       = local.region
}

output "db_security_group_id" {
  description = "RDS security group. example-client temporarily authorizes its public IP on 5432 here for seeding, then revokes it."
  value       = module.rds.security_group_id
}

# --- Database (RDS Postgres) outputs consumed by example-client (seed / clear / least-privilege) ---

output "db_host" {
  description = "RDS Postgres endpoint hostname."
  value       = module.rds.address
}

output "db_port" {
  value = module.rds.port
}

output "db_source_database" {
  description = "Source application database (holds the demo `lists` table)."
  value       = local.source_db
}

output "db_storage_database" {
  description = "PowerSync bucket-storage database."
  value       = local.storage_db
}

output "db_source_username" {
  description = "Least-privilege source/replication role (SELECT + replication)."
  value       = local.source_role
}

output "db_source_password" {
  description = "Password for the source role. Used by example-client seeding (terraform output -raw db_source_password)."
  value       = random_password.pg_source.result
  sensitive   = true
}

output "db_storage_username" {
  description = "Storage role (owns the bucket-storage database)."
  value       = local.storage_role
}

output "db_storage_password" {
  value     = random_password.pg_storage.result
  sensitive = true
}

output "db_master_username" {
  description = "RDS master user. For admin/bootstrap use only."
  value       = module.rds.master_username
}

output "db_master_password" {
  value     = module.rds.master_password
  sensitive = true
}

# --- Client-auth outputs consumed by example-client/auth/mint-token.ts ---

output "jwt_signing_key_secret_arn" {
  description = "Secrets Manager ARN of the RS256 private key (PEM). The local mint script reads it to sign client JWTs."
  value       = aws_secretsmanager_secret.jwt_signing_key.arn
}

output "jwt_signing_kid" {
  description = "kid to set in the JWT header so it matches the ALB-served JWKS."
  value       = local.jwt_kid
}

output "jwt_audience" {
  description = "An audience the deployed PowerSync accepts (config allows powersync-dev + authenticated)."
  value       = "powersync-dev"
}

# --- Observability ---

output "amp_workspace_id" {
  description = "Amazon Managed Prometheus workspace ID (empty when observability is disabled)."
  value       = module.observability.amp_workspace_id
}

output "amp_query_url" {
  description = "AMP query endpoint (empty when observability is disabled)."
  value       = module.observability.amp_query_url
}

output "grafana_workspace_url" {
  description = "AWS Managed Grafana workspace URL (empty when observability is disabled)."
  value       = module.observability.grafana_endpoint == "" ? "" : "https://${module.observability.grafana_endpoint}"
}

output "opensearch_dashboards_url" {
  description = "Native OpenSearch Dashboards URL (empty when OpenSearch is disabled)."
  value       = module.observability.opensearch_dashboards_url
}

output "opensearch_master_user" {
  description = "OpenSearch Dashboards master username."
  value       = module.observability.opensearch_master_user
}

output "opensearch_master_password" {
  description = "OpenSearch Dashboards master password (terraform output -raw opensearch_master_password)."
  value       = module.observability.opensearch_master_password
  sensitive   = true
}

output "alerts_sns_topic_arn" {
  description = "SNS topic all alerts publish to; the alert Lambda subscribes and forwards to the configured destination."
  value       = module.observability.alerts_sns_topic_arn
}

output "alert_logger_log_group" {
  description = "CloudWatch log group where fired alerts are recorded as JSON."
  value       = module.observability.alert_logger_log_group
}

output "execution_role_arn" {
  value = module.iam.execution_role_arn
}

output "task_role_arn" {
  value = module.iam.task_role_arn
}
