###############################################################################
# Log pipeline: CloudWatch Logs subscription -> Lambda -> OpenSearch.
# The Lambda (zero-dep Node ESM) gunzips each CWL batch and bulk-indexes one
# document per log line into daily powersync-logs-* indices. Failed async invokes
# land in an SQS DLQ. The subscription filters + invoke permission live in the ecs
# module (next to the log groups) to avoid an ecs<->observability module cycle.
###############################################################################

data "archive_file" "log_indexer" {
  count       = local.os_enabled ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/cwl-to-opensearch.mjs"
  output_path = "${path.module}/lambda/cwl-to-opensearch.zip"
}

resource "aws_sqs_queue" "log_indexer_dlq" {
  count                     = local.os_enabled ? 1 : 0
  name                      = "${var.name_prefix}-logs-dlq"
  message_retention_seconds = 1209600 # 14 days
}

resource "aws_cloudwatch_log_group" "log_indexer" {
  count             = local.os_enabled ? 1 : 0
  name              = "/aws/lambda/${var.name_prefix}-log-indexer"
  retention_in_days = 14
}

resource "aws_lambda_function" "log_indexer" {
  count            = local.os_enabled ? 1 : 0
  function_name    = "${var.name_prefix}-log-indexer"
  role             = var.log_lambda_role_arn
  runtime          = "nodejs20.x"
  handler          = "cwl-to-opensearch.handler"
  filename         = data.archive_file.log_indexer[0].output_path
  source_code_hash = data.archive_file.log_indexer[0].output_base64sha256
  timeout          = 30
  memory_size      = 256

  # AWS_REGION is injected by the runtime (reserved); we only set our own vars.
  environment {
    variables = {
      OPENSEARCH_ENDPOINT = aws_opensearch_domain.this[0].endpoint
      INDEX_PREFIX        = "powersync-logs"
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.log_indexer_dlq[0].arn
  }

  depends_on = [aws_cloudwatch_log_group.log_indexer]
}
