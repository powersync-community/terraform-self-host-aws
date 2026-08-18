###############################################################################
# Alerting. Two sources -> one SNS topic -> the alert Lambda:
#   - AMP Alertmanager (PowerSync metric alerts: replication lag, replicator down,
#     parameter-storage bloat)
#   - CloudWatch alarms (infra: compaction launch failures, ALB health/5xx, ECS
#     CPU, OpenSearch health)
# The Lambda records each alert as JSON and forwards it to the configured
# destination (log, Slack, or webhook). The SNS topic is the stable seam: swap
# destinations without touching the alarms or rules.
###############################################################################

locals {
  # Forwarding beyond the log needs a webhook URL; without one the Lambda only
  # logs (no secret, no extra IAM), so the base stack stays free.
  alert_webhook_enabled = var.enable_observability && var.alert_destination != "log" && var.alert_webhook_url != ""
}

resource "aws_sns_topic" "alerts" {
  count = var.enable_observability ? 1 : 0
  name  = "${var.name_prefix}-alerts"
}

# Webhook URL for alert forwarding, supplied via the sensitive TF_VAR_alert_webhook_url
# rather than committed. The Lambda reads it from Secrets Manager at runtime.
resource "aws_secretsmanager_secret" "alert_webhook" {
  count       = local.alert_webhook_enabled ? 1 : 0
  name        = "${var.name_prefix}/alert-webhook"
  description = "Incoming webhook URL for forwarding PowerSync alerts."
}

resource "aws_secretsmanager_secret_version" "alert_webhook" {
  count         = local.alert_webhook_enabled ? 1 : 0
  secret_id     = aws_secretsmanager_secret.alert_webhook[0].id
  secret_string = var.alert_webhook_url
}

data "aws_iam_policy_document" "alerts_topic" {
  count = var.enable_observability ? 1 : 0
  statement {
    sid       = "CloudWatchAlarms"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts[0].arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
  }
  statement {
    sid       = "AmpAlertManager"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts[0].arn]
    principals {
      type        = "Service"
      identifiers = ["aps.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_prometheus_workspace.this[0].arn]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  count  = var.enable_observability ? 1 : 0
  arn    = aws_sns_topic.alerts[0].arn
  policy = data.aws_iam_policy_document.alerts_topic[0].json
}

# --- Alert-logger Lambda (default SNS subscriber) ---
data "archive_file" "alert_logger" {
  count       = var.enable_observability ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/alert-logger.mjs"
  output_path = "${path.module}/lambda/alert-logger.zip"
}

resource "aws_cloudwatch_log_group" "alert_logger" {
  count             = var.enable_observability ? 1 : 0
  name              = "/aws/lambda/${var.name_prefix}-alert-logger"
  retention_in_days = 14
}

resource "aws_lambda_function" "alert_logger" {
  count            = var.enable_observability ? 1 : 0
  function_name    = "${var.name_prefix}-alert-logger"
  role             = var.alert_lambda_role_arn
  runtime          = "nodejs20.x"
  handler          = "alert-logger.handler"
  filename         = data.archive_file.alert_logger[0].output_path
  source_code_hash = data.archive_file.alert_logger[0].output_base64sha256
  timeout          = 15
  memory_size      = 128

  environment {
    variables = {
      ALERT_DESTINATION       = var.alert_destination
      ALERT_WEBHOOK_SECRET_ID = local.alert_webhook_enabled ? aws_secretsmanager_secret.alert_webhook[0].name : ""
      ALERT_DASHBOARD_URL     = var.dashboard_uid == "" ? "" : "https://${aws_grafana_workspace.this[0].endpoint}/d/${var.dashboard_uid}"
    }
  }

  depends_on = [aws_cloudwatch_log_group.alert_logger]
}

resource "aws_sns_topic_subscription" "alert_logger" {
  count     = var.enable_observability ? 1 : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.alert_logger[0].arn
}

resource "aws_lambda_permission" "alert_logger_sns" {
  count         = var.enable_observability ? 1 : 0
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.alert_logger[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts[0].arn
}

# --- AMP alerting rules (PowerSync metrics) ---
resource "aws_prometheus_rule_group_namespace" "alerts" {
  count        = var.enable_observability ? 1 : 0
  name         = "${var.name_prefix}-alerts"
  workspace_id = aws_prometheus_workspace.this[0].id

  data = <<-EOT
    groups:
      - name: powersync-alerts
        rules:
          - alert: PowerSyncReplicatorDown
            expr: absent(powersync_replication_lag_seconds)
            for: 5m
            labels: { severity: critical }
            annotations:
              title: "PowerSync — replicator down"
              summary: "No replication_lag metric for 5m — replication may have stopped entirely."
          - alert: PowerSyncReplicationLagCritical
            expr: max(powersync_replication_lag_seconds) > 300
            for: 5m
            labels: { severity: critical }
            annotations:
              title: "PowerSync — replication lag critical"
              summary: "Replication is badly behind the source — clients are seeing stale data."
              value: "{{ $value }}s"
          - alert: PowerSyncReplicationLagHigh
            expr: max(powersync_replication_lag_seconds) > 60
            for: 5m
            labels: { severity: warning }
            annotations:
              title: "PowerSync — replication lag high"
              summary: "Replication lag above 60s for 5m — clients drifting from the source."
              value: "{{ $value }}s"
          - alert: PowerSyncParameterStorageBloat
            expr: powersync:param_bloat:ratio > 0.5
            for: 30m
            labels: { severity: warning }
            annotations:
              title: "PowerSync — parameter storage bloat"
              summary: "Parameter storage exceeds 50% of data storage — precursor to checksum timeouts."
              value: "{{ $value }}"
  EOT
}

# --- AMP Alertmanager -> SNS ---
resource "aws_prometheus_alert_manager_definition" "this" {
  count        = var.enable_observability ? 1 : 0
  workspace_id = aws_prometheus_workspace.this[0].id

  definition = <<-EOT
    alertmanager_config: |
      route:
        receiver: sns
        group_by: [alertname]
        repeat_interval: 4h
      receivers:
        - name: sns
          sns_configs:
            - topic_arn: ${aws_sns_topic.alerts[0].arn}
              sigv4:
                region: ${var.region}
              subject: "PowerSync alert"
              send_resolved: true
              message: '{{ range .Alerts }}POWERSYNC_ALERT|{{ .Status }}|{{ .Labels.severity }}|{{ .Labels.alertname }}|{{ .Annotations.title }}|{{ .Annotations.value }}|{{ .Annotations.summary }}{{ "\n" }}{{ end }}'
  EOT

  depends_on = [aws_sns_topic_policy.alerts]
}

# --- CloudWatch alarms (infra) ---
resource "aws_cloudwatch_metric_alarm" "compaction_failed" {
  count       = var.enable_observability ? 1 : 0
  alarm_name  = "${var.name_prefix}-compaction-launch-failed"
  namespace   = "AWS/Events"
  metric_name = "FailedInvocations"
  dimensions  = { RuleName = "${var.name_prefix}-compact-daily" }
  statistic   = "Sum"
  # The compact rule fires once daily, so FailedInvocations is sparse; evaluate over a
  # full day so a failed run isn't missed by a shorter window.
  period              = 86400
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_description   = "Scheduled compaction failed to launch (EventBridge FailedInvocations)."
  alarm_actions       = [aws_sns_topic.alerts[0].arn]
  ok_actions          = [aws_sns_topic.alerts[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "api_no_healthy_hosts" {
  count               = var.enable_observability && var.alb_arn_suffix != "" ? 1 : 0
  alarm_name          = "${var.name_prefix}-api-no-healthy-hosts"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_description   = "No healthy API targets behind the ALB — sync API unreachable."
  alarm_actions       = [aws_sns_topic.alerts[0].arn]
  ok_actions          = [aws_sns_topic.alerts[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  count               = var.enable_observability && var.alb_arn_suffix != "" ? 1 : 0
  alarm_name          = "${var.name_prefix}-api-target-5xx"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_description   = "API returning 5xx to clients (>10 in 5m)."
  alarm_actions       = [aws_sns_topic.alerts[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "api_cpu_high" {
  count               = var.enable_observability ? 1 : 0
  alarm_name          = "${var.name_prefix}-api-cpu-high"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = "${var.name_prefix}-cluster", ServiceName = "${var.name_prefix}-api" }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_description   = "API service CPU > 85% for 15m (approaching the autoscaling ceiling)."
  alarm_actions       = [aws_sns_topic.alerts[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "opensearch_red" {
  count               = local.os_enabled ? 1 : 0
  alarm_name          = "${var.name_prefix}-opensearch-cluster-red"
  namespace           = "AWS/ES"
  metric_name         = "ClusterStatus.red"
  dimensions          = { DomainName = "${var.name_prefix}-logs", ClientId = var.account_id }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_description   = "OpenSearch cluster status is RED (log search/ingest degraded)."
  alarm_actions       = [aws_sns_topic.alerts[0].arn]
  ok_actions          = [aws_sns_topic.alerts[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "opensearch_low_storage" {
  count               = local.os_enabled ? 1 : 0
  alarm_name          = "${var.name_prefix}-opensearch-low-storage"
  namespace           = "AWS/ES"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DomainName = "${var.name_prefix}-logs", ClientId = var.account_id }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2048
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_description   = "OpenSearch free storage < 2 GB (MB) — indices may soon block writes."
  alarm_actions       = [aws_sns_topic.alerts[0].arn]
}
