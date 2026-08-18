###############################################################################
# Amazon Managed Prometheus (AMP)
#
# Single workspace that receives remote_write from the ADOT collector sidecars
# (modules/ecs). Created only when enable_observability is true. Priced per
# ingested sample.
###############################################################################

resource "aws_prometheus_workspace" "this" {
  count = var.enable_observability ? 1 : 0
  alias = "${var.name_prefix}-metrics"
}
