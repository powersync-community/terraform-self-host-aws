###############################################################################
# Amazon OpenSearch: log search + native Dashboards.
#
# Public-access mode (AWS-provided endpoint, no custom domain/DNS), secured by
# fine-grained access control with an internal master user (for Dashboards login).
# The log-indexer Lambda writes here; its IAM role is mapped to a write role via
# the opensearch provider at the root (FGAC role mapping can't be done via the AWS API).
###############################################################################

locals {
  os_enabled = var.enable_observability && var.enable_opensearch
}

resource "random_password" "opensearch_master" {
  count            = local.os_enabled ? 1 : 0
  length           = 24
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!#$%*-_=+"
}

resource "aws_opensearch_domain" "this" {
  count          = local.os_enabled ? 1 : 0
  domain_name    = "${var.name_prefix}-logs"
  engine_version = "OpenSearch_2.11"

  cluster_config {
    instance_type          = var.opensearch_instance_type
    instance_count         = var.opensearch_instance_count
    zone_awareness_enabled = false
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = var.opensearch_volume_gb
  }

  encrypt_at_rest { enabled = true }
  node_to_node_encryption { enabled = true }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = true
    master_user_options {
      master_user_name     = var.name_prefix
      master_user_password = random_password.opensearch_master[0].result
    }
  }
}

# Separate policy resource so it can reference the domain ARN without a self-cycle.
# With FGAC enabled, authorization is enforced per-user/role; the domain policy is open
# to es:ESHttp* (FGAC is the gate). No IP allowlist for now.
resource "aws_opensearch_domain_policy" "this" {
  count       = local.os_enabled ? 1 : 0
  domain_name = aws_opensearch_domain.this[0].domain_name

  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "*" }
      Action    = "es:ESHttp*"
      Resource  = "${aws_opensearch_domain.this[0].arn}/*"
    }]
  })
}
