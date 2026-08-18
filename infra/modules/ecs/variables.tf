variable "name_prefix" {
  type = string
}

variable "region" {
  type = string
}

variable "image" {
  description = "Full image reference (repo:tag)."
  type        = string
}

variable "log_retention_days" {
  type = number
}

# Networking
variable "private_subnet_ids" {
  type = list(string)
}

variable "ecs_sg_id" {
  type = string
}

variable "target_group_arn" {
  type = string
}

# IAM
variable "execution_role_arn" {
  type = string
}

variable "task_role_arn" {
  type = string
}

variable "events_role_arn" {
  type = string
}

# Config wiring
variable "config_secret_prefix_arn" {
  description = "Prefix ARN (no 6-char suffix) of the powersync/config secret. Used by replication + compact."
  type        = string
}

variable "api_config_secret_prefix_arn" {
  description = "Prefix ARN of the api task's config secret (least-privilege storage user). Used by the api task only."
  type        = string
}

variable "cwagent_param_arn" {
  description = "ARN of the SSM parameter holding the cw-agent EMF config."
  type        = string
}

variable "prometheus_port" {
  type = number
}

# Observability (opt-in). true: the api task's metrics sidecar is an ADOT collector that
# remote-writes to AMP and publishes the autoscaling metric to CloudWatch. false: the
# metrics sidecar is the cw-agent, publishing the autoscaling metric only.
variable "enable_observability" {
  type    = bool
  default = false
}

variable "amp_remote_write_url" {
  description = "AMP remote_write endpoint the ADOT sidecar pushes to. Required when enable_observability = true."
  type        = string
  default     = ""
}

# Log shipping to OpenSearch. Subscription filters on the app log groups live here,
# next to the groups, to avoid an ecs<->observability module cycle; they target the
# log-indexer Lambda.
variable "enable_opensearch" {
  type    = bool
  default = false
}

variable "log_lambda_arn" {
  description = "ARN of the log-indexer Lambda the subscription filters target."
  type        = string
  default     = ""
}

variable "log_lambda_function_name" {
  description = "Name of the log-indexer Lambda (for the CloudWatch Logs invoke permission)."
  type        = string
  default     = ""
}

# Sizing — API
variable "api_cpu" {
  type = number
}

variable "api_memory" {
  type = number
}

variable "api_node_options" {
  type = string
}

# Sizing — replication
variable "replication_cpu" {
  type = number
}

variable "replication_memory" {
  type = number
}

variable "replication_node_options" {
  type = string
}

# Sizing — compact
variable "compact_cpu" {
  type = number
}

variable "compact_memory" {
  type = number
}

variable "compact_node_options" {
  type = string
}

variable "compact_schedule" {
  type = string
}

# Service behavior
variable "health_check_grace" {
  type = number
}

variable "stop_timeout" {
  type = number
}

# Autoscaling
variable "api_min_capacity" {
  type = number
}

variable "api_max_capacity" {
  type = number
}

variable "connection_target" {
  type = number
}

variable "cpu_target" {
  type = number
}

variable "scale_out_cooldown" {
  type = number
}

variable "scale_in_cooldown" {
  type = number
}
