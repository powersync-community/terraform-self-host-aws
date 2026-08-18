variable "name_prefix" {
  type = string
}

variable "region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "path" {
  description = "IAM path for created roles."
  type        = string
  default     = "/powersync/"
}

variable "create_iam_roles" {
  type = bool
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary attached to every role created here. The account requires it on all IAM roles (SandboxRoleBoundary); CreateRole is denied without it. null = omit."
  type        = string
  default     = null
}

variable "existing_execution_role_arn" {
  type    = string
  default = ""
}

variable "existing_task_role_arn" {
  type    = string
  default = ""
}

variable "existing_events_role_arn" {
  type    = string
  default = ""
}

variable "enable_observability" {
  description = "When true, grant the task role aps:RemoteWrite and create the Grafana workspace role."
  type        = bool
  default     = false
}

variable "enable_opensearch" {
  description = "When true (with enable_observability), create the log-indexer Lambda's execution role for the OpenSearch log pipeline."
  type        = bool
  default     = false
}

variable "enable_alert_webhook" {
  description = "When true, let the alert Lambda read the webhook-URL secret (secretsmanager:GetSecretValue on <name_prefix>/alert-webhook)."
  type        = bool
  default     = false
}
