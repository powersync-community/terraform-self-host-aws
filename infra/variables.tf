###############################################################################
# Inputs. Secret / account-identifying values are marked sensitive and are meant
# to be supplied via TF_VAR_* env vars (see ../.env.example). None carries a
# committed secret default. Everything else (sizing, CIDRs, timeouts, schedules)
# is hard-coded in locals.tf or inline at the call site in main.tf.
###############################################################################

variable "deployment_name" {
  description = <<-EOT
    Short, unique name for THIS deployment. It prefixes every named resource, so multiple
    independent deployments can coexist in the same AWS account and region. Also used as the
    subdomain (<deployment_name>.<base_domain>) and should match the first segment of the
    S3 state key in versions.tf. Lowercase letters/digits/hyphens, 2-24 chars.
  EOT
  type        = string
  default     = "powersync"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,23}$", var.deployment_name))
    error_message = "deployment_name must be 2-24 chars, start with a letter, and contain only lowercase letters, digits, and hyphens."
  }
}

variable "account_id" {
  description = "Expected AWS account ID. A guard aborts the plan if the active credentials resolve to a different account."
  type        = string
}

variable "base_domain" {
  description = "Parent domain whose Route 53 zone you own (e.g. example.com). The ALB is published at <deployment_name>.<base_domain>."
  type        = string
}

variable "route53_zone_id" {
  description = "ID of the existing Route 53 hosted zone that owns base_domain. Terraform requests the ACM cert and creates the alias here."
  type        = string
}

variable "admin_cidr" {
  description = <<-EOT
    CIDR blocks allowed to reach the RDS instance on 5432 in addition to the ECS tasks, e.g.
    your workstation IP as ["203.0.113.4/32"] for seeding and running the example client locally.
    Leave empty to allow only in-VPC access (then seed via a bastion/SSM tunnel).
  EOT
  type        = list(string)
  default     = []
}

variable "iam_permissions_boundary" {
  description = "Optional name of an IAM policy to attach as a permissions boundary on every role created here. Built as arn:aws:iam::<account_id>:policy/<this>. Leave \"\" if your account has no such requirement."
  type        = string
  default     = ""
}

# --- Database sizing (RDS Postgres) ---
variable "db_instance_class" {
  description = "RDS instance class for the Postgres database."
  type        = string
  default     = "db.t3.medium"
}

variable "db_allocated_storage" {
  description = "Allocated storage (GiB) for the RDS Postgres instance."
  type        = number
  default     = 20
}

variable "postgres_version" {
  description = "Postgres major version. 14+ is required to co-locate the source and bucket-storage databases on one instance."
  type        = string
  default     = "16"
}

# --- PowerSync admin/management API ---
variable "admin_api_token" {
  description = "Bearer token accepted by the PowerSync admin/management API (rendered into api.tokens). Supplied via TF_VAR_admin_api_token. Leave \"\" to disable the admin API."
  type        = string
  sensitive   = true
  default     = ""
}

# --- Observability (only relevant when enable_observability = true in locals.tf) ---
variable "grafana_admin_user_id" {
  description = "IAM Identity Center user ID granted Grafana ADMIN on the AMG workspace. Leave \"\" to assign users in the AMG console instead."
  type        = string
  default     = ""
}

variable "alert_destination" {
  description = "Where observability alerts go in addition to the durable CloudWatch log: log | slack | webhook. slack/webhook require alert_webhook_url."
  type        = string
  default     = "log"
}

variable "alert_webhook_url" {
  description = "Incoming webhook URL for alert forwarding (Slack or generic). Stored in Secrets Manager, never committed. Required when alert_destination is slack or webhook."
  type        = string
  sensitive   = true
  default     = ""
}

# --- MongoDB Atlas (ONLY for the optional commented-out Atlas example in main.tf) ---
# Uncomment these and the atlas module/provider if you swap RDS for Atlas as the data layer.
# variable "atlas_client_id" {
#   description = "Atlas Service Account client ID (OAuth2), project-scoped Project Owner."
#   type        = string
#   sensitive   = true
# }
# variable "atlas_client_secret" {
#   description = "Atlas Service Account client secret (OAuth2)."
#   type        = string
#   sensitive   = true
# }
# variable "atlas_project_id" {
#   description = "Atlas project ID the cluster is created in."
#   type        = string
#   sensitive   = true
# }
