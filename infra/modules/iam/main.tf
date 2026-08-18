locals {
  create = var.create_iam_roles
  c      = local.create ? 1 : 0

  # Effective ARNs used by both this module's policies and the ecs module.
  execution_role_arn = local.create ? aws_iam_role.execution[0].arn : var.existing_execution_role_arn
  task_role_arn      = local.create ? aws_iam_role.task[0].arn : var.existing_task_role_arn
  events_role_arn    = local.create ? aws_iam_role.events[0].arn : var.existing_events_role_arn

  secrets_arn_wildcard = "arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${var.name_prefix}/*"
  ssm_arn_wildcard     = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/ecs/${var.name_prefix}/*"
  compact_taskdef_arn  = "arn:aws:ecs:${var.region}:${var.account_id}:task-definition/${var.name_prefix}-compact:*"
}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

###############################################################################
# Task execution role — pulls secrets/SSM and the image, writes logs.
###############################################################################

resource "aws_iam_role" "execution" {
  count                = local.c
  name                 = "${var.name_prefix}-tf-execution"
  path                 = var.path
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  count      = local.c
  role       = aws_iam_role.execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  statement {
    sid       = "SecretsAccess"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.secrets_arn_wildcard]
  }
  statement {
    sid       = "SSMParameterAccess"
    actions   = ["ssm:GetParameters"]
    resources = [local.ssm_arn_wildcard]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  count  = local.c
  name   = "SecretsAndSSMAccess"
  role   = aws_iam_role.execution[0].id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

###############################################################################
# Task role — cw-agent sidecar publishes metrics + writes EMF logs.
###############################################################################

resource "aws_iam_role" "task" {
  count                = local.c
  name                 = "${var.name_prefix}-tf-task"
  path                 = var.path
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "task_cloudwatch" {
  statement {
    sid = "CloudWatchMetrics"
    actions = [
      "cloudwatch:PutMetricData",
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task_cloudwatch" {
  count  = local.c
  name   = "CloudWatchMetrics"
  role   = aws_iam_role.task[0].id
  policy = data.aws_iam_policy_document.task_cloudwatch.json
}

# AMP remote-write — granted when observability is enabled so the ADOT sidecar can
# push metrics to the AMP workspace. Its awsemf exporter (autoscaling metric) is
# covered by the CloudWatchMetrics policy above.
data "aws_iam_policy_document" "task_amp" {
  count = var.enable_observability ? 1 : 0
  statement {
    sid       = "PrometheusRemoteWrite"
    actions   = ["aps:RemoteWrite"]
    resources = ["arn:aws:aps:${var.region}:${var.account_id}:workspace/*"]
  }
}

resource "aws_iam_role_policy" "task_amp" {
  count  = local.create && var.enable_observability ? 1 : 0
  name   = "PrometheusRemoteWrite"
  role   = aws_iam_role.task[0].id
  policy = data.aws_iam_policy_document.task_amp[0].json
}

###############################################################################
# Grafana workspace role — AMG (CUSTOMER_MANAGED) assumes this to query AMP +
# CloudWatch. Created only when observability is enabled.
###############################################################################

data "aws_iam_policy_document" "grafana_assume" {
  count = var.enable_observability ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["grafana.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "grafana" {
  count                = local.create && var.enable_observability ? 1 : 0
  name                 = "${var.name_prefix}-tf-grafana"
  path                 = var.path
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.grafana_assume[0].json
}

resource "aws_iam_role_policy_attachment" "grafana_amp" {
  count      = local.create && var.enable_observability ? 1 : 0
  role       = aws_iam_role.grafana[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonPrometheusQueryAccess"
}

# CloudWatch + Logs read for the Grafana datasource. Inline (there is no single AWS-managed
# "Grafana CloudWatch" policy); covers metrics, Logs Insights, and alarm reads.
data "aws_iam_policy_document" "grafana_cloudwatch" {
  count = var.enable_observability ? 1 : 0
  statement {
    sid = "CloudWatchMetricsAndLogsRead"
    actions = [
      "cloudwatch:DescribeAlarmsForMetric",
      "cloudwatch:DescribeAlarmHistory",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:GetInsightRuleReport",
      "logs:DescribeLogGroups",
      "logs:GetLogGroupFields",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:GetQueryResults",
      "logs:GetLogEvents",
      "ec2:DescribeRegions",
      "tag:GetResources",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "grafana_cloudwatch" {
  count  = local.create && var.enable_observability ? 1 : 0
  name   = "GrafanaCloudWatchAccess"
  role   = aws_iam_role.grafana[0].id
  policy = data.aws_iam_policy_document.grafana_cloudwatch[0].json
}

###############################################################################
# Log-indexer Lambda role (OpenSearch) — assumed by the CloudWatch-Logs->OpenSearch
# Lambda. ARNs are constructed from name_prefix/region/account so this module does
# not depend on the observability module (avoids a cycle).
###############################################################################

locals {
  os            = var.enable_observability && var.enable_opensearch
  os_domain_arn = "arn:aws:es:${var.region}:${var.account_id}:domain/${var.name_prefix}-logs"
  os_dlq_arn    = "arn:aws:sqs:${var.region}:${var.account_id}:${var.name_prefix}-logs-dlq"
}

data "aws_iam_policy_document" "log_lambda_assume" {
  count = local.os ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "log_lambda" {
  count                = local.create && local.os ? 1 : 0
  name                 = "${var.name_prefix}-tf-log-indexer"
  path                 = var.path
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.log_lambda_assume[0].json
}

data "aws_iam_policy_document" "log_lambda" {
  count = local.os ? 1 : 0
  statement {
    sid       = "OwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.region}:${var.account_id}:log-group:/aws/lambda/${var.name_prefix}-log-indexer:*"]
  }
  statement {
    sid       = "OpenSearchWrite"
    actions   = ["es:ESHttpPost", "es:ESHttpPut", "es:ESHttpGet"]
    resources = ["${local.os_domain_arn}/*"]
  }
  statement {
    sid       = "DeadLetter"
    actions   = ["sqs:SendMessage"]
    resources = [local.os_dlq_arn]
  }
}

resource "aws_iam_role_policy" "log_lambda" {
  count  = local.create && local.os ? 1 : 0
  name   = "LogIndexer"
  role   = aws_iam_role.log_lambda[0].id
  policy = data.aws_iam_policy_document.log_lambda[0].json
}

# --- Alert-logger Lambda role (SNS -> logs). Only basic logging is needed. ---
data "aws_iam_policy_document" "alert_lambda_assume" {
  count = var.enable_observability ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alert_lambda" {
  count                = local.create && var.enable_observability ? 1 : 0
  name                 = "${var.name_prefix}-tf-alert-logger"
  path                 = var.path
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.alert_lambda_assume[0].json
}

data "aws_iam_policy_document" "alert_lambda" {
  count = var.enable_observability ? 1 : 0
  statement {
    sid       = "OwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.region}:${var.account_id}:log-group:/aws/lambda/${var.name_prefix}-alert-logger:*"]
  }
  dynamic "statement" {
    for_each = var.enable_alert_webhook ? [1] : []
    content {
      sid       = "ReadWebhookSecret"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = ["arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${var.name_prefix}/alert-webhook-*"]
    }
  }
}

resource "aws_iam_role_policy" "alert_lambda" {
  count  = local.create && var.enable_observability ? 1 : 0
  name   = "AlertLogger"
  role   = aws_iam_role.alert_lambda[0].id
  policy = data.aws_iam_policy_document.alert_lambda[0].json
}

###############################################################################
# EventBridge role — runs the scheduled compact task.
###############################################################################

resource "aws_iam_role" "events" {
  count                = local.c
  name                 = "${var.name_prefix}-tf-events"
  path                 = var.path
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.events_assume.json
}

data "aws_iam_policy_document" "events_runtask" {
  statement {
    sid       = "RunCompactTask"
    actions   = ["ecs:RunTask"]
    resources = [local.compact_taskdef_arn]
  }
  statement {
    sid       = "PassTaskRoles"
    actions   = ["iam:PassRole"]
    resources = [local.execution_role_arn, local.task_role_arn]
  }
}

resource "aws_iam_role_policy" "events_runtask" {
  count  = local.c
  name   = "ECS-Events-Policy"
  role   = aws_iam_role.events[0].id
  policy = data.aws_iam_policy_document.events_runtask.json
}
