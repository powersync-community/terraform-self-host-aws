# Single config secret. The rendered+base64 service.yaml carries the creds, so they live
# here and are referenced by the task defs only by prefix ARN — never inlined into a task def.
# recovery_window_in_days = 0 so destroy/apply can recreate the name immediately.
resource "aws_secretsmanager_secret" "config" {
  name                    = var.config_secret_name
  description             = "PowerSync base64 service.yaml (POWERSYNC_CONFIG_B64)"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "config" {
  secret_id     = aws_secretsmanager_secret.config.id
  secret_string = var.config_b64
}

# Separate config for the client-facing API task: identical except its storage connection uses
# the least-privilege API user. Only the api task def references this secret.
resource "aws_secretsmanager_secret" "config_api" {
  name                    = var.config_api_secret_name
  description             = "PowerSync base64 service.yaml for the -r api task (least-privilege storage user)"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "config_api" {
  secret_id     = aws_secretsmanager_secret.config_api.id
  secret_string = var.config_api_b64
}

# cw-agent EMF config consumed by the sidecar via the CW_CONFIG_CONTENT secret reference.
resource "aws_ssm_parameter" "cwagent" {
  name  = var.cwagent_param_name
  type  = "String"
  value = var.cwagent_config
}
