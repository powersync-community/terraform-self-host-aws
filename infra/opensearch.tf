###############################################################################
# OpenSearch FGAC role mapping (via the opensearch provider, configured in
# providers.tf with the internal master user). Maps the log-indexer Lambda's role
# to a write role so it can create the daily indices and bulk-write log documents.
# Required because FGAC role mapping is not exposed through the AWS API.
###############################################################################

resource "opensearch_role" "logs_writer" {
  count     = local.enable_opensearch ? 1 : 0
  role_name = "powersync_logs_writer"

  cluster_permissions = ["cluster_composite_ops", "cluster_monitor"]

  index_permissions {
    index_patterns  = ["powersync-logs*"]
    allowed_actions = ["crud", "create_index", "manage"]
  }
}

resource "opensearch_roles_mapping" "log_indexer" {
  count         = local.enable_opensearch ? 1 : 0
  role_name     = opensearch_role.logs_writer[0].role_name
  backend_roles = [module.iam.log_lambda_role_arn]
}

###############################################################################
# OpenSearch Dashboards saved objects — created in the Global tenant (.kibana)
# so Dashboards/Discover works out of the box with no manual click:
#   - the powersync-logs-* index pattern (time field @timestamp)
#   - a default "PowerSync logs" search with useful columns
###############################################################################

resource "opensearch_dashboard_object" "index_pattern" {
  count = local.enable_opensearch ? 1 : 0
  body = jsonencode([
    {
      _id = "index-pattern:powersync-logs"
      _source = {
        type       = "index-pattern"
        references = []
        "index-pattern" = {
          title         = "powersync-logs-*"
          timeFieldName = "@timestamp"
        }
      }
    }
  ])

  depends_on = [opensearch_roles_mapping.log_indexer]
}

resource "opensearch_dashboard_object" "logs_search" {
  count = local.enable_opensearch ? 1 : 0
  body = jsonencode([
    {
      _id = "search:powersync-logs"
      _source = {
        type = "search"
        search = {
          title       = "PowerSync logs"
          columns     = ["log_group", "level", "message"]
          sort        = [["@timestamp", "desc"]]
          description = "All PowerSync service logs, newest first."
          kibanaSavedObjectMeta = {
            searchSourceJSON = jsonencode({
              index  = "index-pattern:powersync-logs"
              query  = { query = "", language = "lucene" }
              filter = []
            })
          }
        }
        references = [
          {
            id   = "index-pattern:powersync-logs"
            name = "kibanaSavedObjectMeta.searchSourceJSON.index"
            type = "index-pattern"
          }
        ]
      }
    }
  ])

  depends_on = [opensearch_dashboard_object.index_pattern]
}
