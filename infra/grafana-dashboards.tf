###############################################################################
# Grafana datasources + dashboard, managed via the grafana provider (configured
# in providers.tf from the AMG workspace + service-account token). All gated by
# enable_observability. The dashboard's datasource template variables resolve to
# these by type (AMP is marked default for the prometheus variable).
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

resource "grafana_data_source" "opensearch" {
  count               = local.enable_opensearch ? 1 : 0
  type                = "elasticsearch"
  name                = "OpenSearch"
  url                 = "https://${module.observability.opensearch_endpoint}"
  basic_auth_enabled  = true
  basic_auth_username = module.observability.opensearch_master_user

  json_data_encoded = jsonencode({
    index                      = "powersync-logs-*"
    timeField                  = "@timestamp"
    esVersion                  = "7.10.0"
    maxConcurrentShardRequests = 5
    logMessageField            = "message"
    logLevelField              = "level"
  })

  secure_json_data_encoded = jsonencode({
    basicAuthPassword = module.observability.opensearch_master_password
  })
}

resource "grafana_dashboard" "overview" {
  count       = local.enable_observability ? 1 : 0
  config_json = file("${path.module}/dashboards/powersync-overview.json")

  depends_on = [grafana_data_source.amp, grafana_data_source.cloudwatch, grafana_data_source.opensearch]
}
