variable "name_prefix" {
  type = string
}

variable "enable_observability" {
  description = "Master toggle for the observability stack. false creates no resources."
  type        = bool
  default     = false
}

variable "grafana_role_arn" {
  description = "Customer-managed IAM role ARN the AMG workspace assumes to query AMP + CloudWatch. Required when enable_observability."
  type        = string
  default     = ""
}

variable "grafana_admin_user_id" {
  description = "IAM Identity Center user ID granted Grafana ADMIN. Empty = assign users in the console."
  type        = string
  default     = ""
}

# --- Log pipeline (OpenSearch) ---
variable "enable_opensearch" {
  description = "When true (with enable_observability), create the OpenSearch domain and the log pipeline (CloudWatch Logs -> indexer Lambda -> OpenSearch)."
  type        = bool
  default     = false
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "account_id" {
  type    = string
  default = ""
}

variable "log_lambda_role_arn" {
  description = "Execution role for the CloudWatch-Logs->OpenSearch indexer Lambda."
  type        = string
  default     = ""
}

variable "alert_lambda_role_arn" {
  description = "Execution role for the SNS alert-logger Lambda."
  type        = string
  default     = ""
}

variable "alert_destination" {
  description = "Where alerts are forwarded in addition to the durable CloudWatch log: log | slack | webhook. slack/webhook require alert_webhook_url."
  type        = string
  default     = "log"
  validation {
    condition     = contains(["log", "slack", "webhook"], var.alert_destination)
    error_message = "alert_destination must be one of: log, slack, webhook."
  }
}

variable "alert_webhook_url" {
  description = "Incoming webhook URL for alert forwarding (Slack or generic). Stored in Secrets Manager, never in code, supply via TF_VAR_alert_webhook_url. Required when alert_destination is slack or webhook."
  type        = string
  default     = ""
  sensitive   = true
}

variable "dashboard_uid" {
  description = "UID of the Grafana overview dashboard, used to build the 'View in Grafana' deep link for metric alerts. Empty disables the link."
  type        = string
  default     = ""
}

# ALB CloudWatch dimension values, for the ALB alarms.
variable "alb_arn_suffix" {
  type    = string
  default = ""
}

variable "target_group_arn_suffix" {
  type    = string
  default = ""
}

variable "opensearch_instance_type" {
  type    = string
  default = "t3.small.search"
}

variable "opensearch_instance_count" {
  type    = number
  default = 1
}

variable "opensearch_volume_gb" {
  type    = number
  default = 20
}
