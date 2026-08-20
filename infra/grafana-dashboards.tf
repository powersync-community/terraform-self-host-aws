###############################################################################
# Grafana datasources + dashboard, managed via the grafana provider (configured
# in providers.tf from the AMG workspace + service-account token). All gated by
# enable_observability. The dashboard's datasource template variables resolve to
# these by type (AMP is marked default for the prometheus variable).
#
# Grafana queries metrics from AMP and CloudWatch, and reads logs through CloudWatch
# Logs Insights. It does not query OpenSearch: Amazon Managed Grafana does not install
# the OpenSearch datasource plugin, so deep OpenSearch log search happens in the native
# OpenSearch Dashboards instead (the opensearch_dashboards_url output).
###############################################################################

resource "grafana_data_source" "amp" {
  count      = local.enable_observability ? 1 : 0
  type       = "prometheus"
  name       = "Amazon Managed Prometheus"
  url        = module.observability.amp_query_url
  is_default = true

  json_data_encoded = jsonencode({
    httpMethod    = "POST"
    sigV4Auth     = true
    sigV4AuthType = "default"
    sigV4Region   = local.region
  })
}

resource "grafana_data_source" "cloudwatch" {
  count = local.enable_observability ? 1 : 0
  type  = "cloudwatch"
  name  = "CloudWatch"

  json_data_encoded = jsonencode({
    authType      = "default"
    defaultRegion = local.region
  })
}

###############################################################################
# Dashboard rendering.
#
# The committed dashboard JSON is written for the default deployment_name ("powersync"): its log-group
# filters, CloudWatch dimension constants, compact rule name, and uid all carry the "powersync-"
# prefix. Rendering rewrites that prefix to this deployment's name_prefix so every panel matches the
# real log groups and dimensions. (Metric names use "powersync_"/"powersync:" and are untouched.)
#
# The log rows (Errors, Logs) are appended from cw-log-panels.json, which queries CloudWatch Logs
# Insights through the CloudWatch datasource.
###############################################################################

locals {
  dashboard_src       = jsondecode(file("${path.module}/dashboards/powersync-overview.json"))
  dashboard_cw_panels = jsondecode(file("${path.module}/dashboards/cw-log-panels.json"))

  dashboard_rendered = merge(local.dashboard_src, {
    panels = concat(local.dashboard_src.panels, local.dashboard_cw_panels)
  })

  dashboard_json = replace(jsonencode(local.dashboard_rendered), "powersync-", "${local.name_prefix}-")
}

resource "grafana_dashboard" "overview" {
  count       = local.enable_observability ? 1 : 0
  config_json = local.dashboard_json

  depends_on = [grafana_data_source.amp, grafana_data_source.cloudwatch]
}
