provider "aws" {
  region = local.region

  default_tags {
    tags = local.common_tags
  }
}

# AMG (Amazon Managed Grafana). url/auth come from the workspace + service-account token
# created in module.observability. Both resolve to "" when observability is disabled, in
# which case no grafana_* resources are created and the provider is never invoked.
provider "grafana" {
  url  = local.enable_observability ? "https://${module.observability.grafana_endpoint}" : ""
  auth = local.enable_observability ? module.observability.grafana_auth_token : ""
}

# OpenSearch, used only for FGAC role mapping (log-indexer Lambda role -> write). Authenticated
# with the internal master user. url/creds are "" when enable_opensearch is false, in
# which case no opensearch_* resources are created and the provider is never invoked.
provider "opensearch" {
  url               = local.enable_opensearch ? "https://${module.observability.opensearch_endpoint}" : ""
  username          = local.enable_opensearch ? module.observability.opensearch_master_user : ""
  password          = local.enable_opensearch ? module.observability.opensearch_master_password : ""
  healthcheck       = false
  sign_aws_requests = false
}

# NOTE: the optional MongoDB Atlas example (modules/atlas-cluster, commented out in main.tf)
# also needs its provider configured. Uncomment alongside that path:
#
# provider "mongodbatlas" {
#   client_id     = var.atlas_client_id
#   client_secret = var.atlas_client_secret
# }
