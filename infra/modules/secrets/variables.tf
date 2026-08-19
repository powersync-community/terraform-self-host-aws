variable "config_secret_name" {
  description = "Secrets Manager secret name, e.g. powersync/config."
  type        = string
}

variable "config_b64" {
  description = "Base64-encoded rendered service.yaml. Holds the Postgres URIs + JWKS URL."
  type        = string
  sensitive   = true
}

variable "config_api_secret_name" {
  description = "Secrets Manager secret name for the api task's config, e.g. powersync/config-api."
  type        = string
}

variable "config_api_b64" {
  description = "Base64-encoded service.yaml for the api task, storage uses the least-privilege user."
  type        = string
  sensitive   = true
}

variable "cwagent_param_name" {
  description = "SSM parameter name for the cw-agent EMF config, e.g. /ecs/powersync/cwagent-config."
  type        = string
}

variable "cwagent_config" {
  description = "cw-agent EMF config JSON."
  type        = string
}
