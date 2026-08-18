###############################################################################
# AMP recording rules — materialize the derived signals once so dashboards and
# alerts reference the same named series (single source of truth). Names match the
# series the dashboard panels query.
###############################################################################

resource "aws_prometheus_rule_group_namespace" "derived" {
  count        = var.enable_observability ? 1 : 0
  name         = "${var.name_prefix}-derived"
  workspace_id = aws_prometheus_workspace.this[0].id

  data = <<-EOT
    groups:
      - name: powersync-derived
        interval: 30s
        rules:
          - record: powersync:replication_rate:rows5m
            expr: sum(rate(powersync_rows_replicated_total[5m]))
          - record: powersync:ops_synced:rate5m
            expr: sum(rate(powersync_operations_synced_total[5m]))
          - record: powersync:compression:ratio5m
            expr: sum(rate(powersync_data_sent_bytes_total[5m])) / clamp_min(sum(rate(powersync_data_synced_bytes_total[5m])), 1)
          - record: powersync:bytes_per_conn:5m
            expr: sum(rate(powersync_data_synced_bytes_total[5m])) / clamp_min(sum(powersync_concurrent_connections), 1)
          - record: powersync:ops_per_row:5m
            expr: sum(rate(powersync_operations_synced_total[5m])) / clamp_min(sum(rate(powersync_rows_replicated_total[5m])), 1)
          - record: powersync:param_bloat:ratio
            expr: sum(powersync_parameter_storage_size_bytes) / clamp_min(sum(powersync_replication_storage_size_bytes) + sum(powersync_operation_storage_size_bytes), 1)
  EOT
}
