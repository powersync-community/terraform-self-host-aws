#!/usr/bin/env bash
#
# Test the alert pipeline end-to-end: CloudWatch alarm -> SNS -> alert Lambda ->
# configured destination (log / Slack / webhook).
#
# It uses `set-alarm-state`, which fires the alarm's SNS actions immediately.
# CloudWatch resets the alarm on the next real metric evaluation, so this is a
# safe, repeatable synthetic test that changes no infrastructure.
#
# Usage:
#   scripts/test-alert.sh [ALARM_NAME] [STATE]
#     ALARM_NAME  defaults to powersync-api-cpu-high
#     STATE       ALARM (default) | OK . Run ALARM then OK to test both paths
#
# Requires AWS credentials with cloudwatch:SetAlarmState (set AWS_PROFILE first).

set -euo pipefail

ALARM="${1:-powersync-api-cpu-high}"
STATE="${2:-ALARM}"
REASON="synthetic alert-pipeline test $(date -u +%FT%TZ)"

aws cloudwatch set-alarm-state \
  --alarm-name "$ALARM" \
  --state-value "$STATE" \
  --state-reason "$REASON"

echo "Set '$ALARM' -> $STATE."
echo "Watch it arrive at the destination, and confirm the durable log record with:"
echo "  aws logs tail /aws/lambda/powersync-alert-logger --since 2m --follow"
