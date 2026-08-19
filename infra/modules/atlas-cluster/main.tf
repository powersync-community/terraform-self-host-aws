terraform {
  required_providers {
    mongodbatlas = {
      source  = "mongodb/mongodbatlas"
      version = "~> 2.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

###############################################################################
# Cluster: single-region replica set on AWS.
#
# provider 2.0 schema: replication_specs / region_configs / electable_specs are
# list-of-object attributes (the `= [ { ... } ]` form), not nested blocks.
# node_count = 3 is the standard Atlas replica set (the only electable layout M10 offers).
# priority = 7 marks the (single) region as primary.
###############################################################################

resource "mongodbatlas_advanced_cluster" "this" {
  project_id             = var.project_id
  name                   = "${var.name_prefix}-cluster"
  cluster_type           = "REPLICASET"
  mongo_db_major_version = var.mongo_db_major_version

  replication_specs = [
    {
      region_configs = [
        {
          provider_name = "AWS"
          region_name   = var.region_name
          priority      = 7

          electable_specs = {
            instance_size = var.instance_size
            node_count    = 3
          }
        }
      ]
    }
  ]
}

###############################################################################
# Per-connection database users (Phase B): generated passwords, never committed.
# One user per connection, each scoped to exactly the database it touches:
#   - source: readWrite@<source_database>  (source data + the connector's _powersync_checkpoints)
#   - full:   readWrite@<storage_database> (bucket storage, used by replication/compact)
# The api process uses the separate least-privilege user below for storage.
# special=false on the passwords avoids URL-encoding headaches in the mongodb+srv:// strings.
###############################################################################

resource "random_password" "source" {
  length  = 32
  special = false
}

resource "mongodbatlas_database_user" "source" {
  project_id         = var.project_id
  username           = "${var.db_username}_source"
  password           = random_password.source.result
  auth_database_name = "admin"

  roles {
    role_name     = "readWrite"
    database_name = var.source_database
  }
}

resource "random_password" "full" {
  length  = 32
  special = false
}

resource "mongodbatlas_database_user" "full" {
  project_id         = var.project_id
  username           = "${var.db_username}_full"
  password           = random_password.full.result
  auth_database_name = "admin"

  roles {
    role_name     = "readWrite"
    database_name = var.storage_database
  }
}

###############################################################################
# Least-privilege user for the client-facing API process (-r api), Phase A.
#
# The API server reads bucket storage to serve clients and writes only two collections
# (write_checkpoints, connection_report_events). It never writes bucket data; that's the
# replicator (-r sync), which keeps the broad readWriteAnyDatabase user above.
#
# Note: this role has insert but not createCollection, so those two collections must already
# exist (created by the full-access replicator/migration) before the API user writes to them.
###############################################################################

resource "mongodbatlas_custom_db_role" "api_storage" {
  project_id = var.project_id
  role_name  = var.api_role_name

  # read@<storage_database>: find + list across the whole storage db.
  actions {
    action = "FIND"
    resources {
      database_name   = var.storage_database
      collection_name = ""
    }
  }
  actions {
    action = "LIST_COLLECTIONS"
    resources {
      database_name   = var.storage_database
      collection_name = ""
    }
  }

  # Writes confined to the two collections the API maintains. Atlas requires each action to
  # appear once, with every target collection listed as a separate resources block under it.
  actions {
    action = "INSERT"
    resources {
      database_name   = var.storage_database
      collection_name = "write_checkpoints"
    }
    resources {
      database_name   = var.storage_database
      collection_name = "connection_report_events"
    }
  }
  actions {
    action = "UPDATE"
    resources {
      database_name   = var.storage_database
      collection_name = "write_checkpoints"
    }
    resources {
      database_name   = var.storage_database
      collection_name = "connection_report_events"
    }
  }
  actions {
    action = "REMOVE"
    resources {
      database_name   = var.storage_database
      collection_name = "connection_report_events"
    }
  }
}

resource "random_password" "api" {
  length  = 32
  special = false
}

resource "mongodbatlas_database_user" "api" {
  project_id         = var.project_id
  username           = "${var.db_username}_api"
  password           = random_password.api.result
  auth_database_name = "admin"

  roles {
    role_name     = mongodbatlas_custom_db_role.api_storage.role_name
    database_name = "admin" # custom roles are assigned from the admin db
  }
}

###############################################################################
# PrivateLink: Atlas side + the AWS interface endpoint + the link-back (auto-approval).
#
# Chain: privatelink_endpoint (Atlas issues a service name) -> aws_vpc_endpoint (we create
# the interface endpoint from it) -> privatelink_endpoint_service (hands the AWS endpoint id
# back to Atlas; this is the old manual "approve in Atlas" step). Terraform orders it for us.
#
# private_dns_enabled = false: the standard mongodb+srv host won't resolve here; the cluster's
# private_endpoint (-pri) SRV string is what connects (assembled into the URIs in locals.tf).
###############################################################################

# Endpoint resources are created only by the instance that owns the regional endpoint
# (create_private_endpoint = true). A second cluster in the same region reuses it (count = 0)
# and resolves its -pri string via var.existing_vpc_endpoint_id.
resource "mongodbatlas_privatelink_endpoint" "this" {
  count         = var.create_private_endpoint ? 1 : 0
  project_id    = var.project_id
  provider_name = "AWS"
  region        = var.region_name
}

resource "aws_vpc_endpoint" "atlas" {
  count               = var.create_private_endpoint ? 1 : 0
  vpc_id              = var.vpc_id
  service_name        = mongodbatlas_privatelink_endpoint.this[0].endpoint_service_name
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [var.endpoint_sg_id]
  private_dns_enabled = false

  tags = { Name = "${var.name_prefix}-atlas-endpoint" }
}

resource "mongodbatlas_privatelink_endpoint_service" "this" {
  count               = var.create_private_endpoint ? 1 : 0
  project_id          = var.project_id
  private_link_id     = mongodbatlas_privatelink_endpoint.this[0].private_link_id
  endpoint_service_id = aws_vpc_endpoint.atlas[0].id
  provider_name       = "AWS"
}

# The id of the endpoint this cluster's -pri string is matched against: the one we created, or the
# shared regional endpoint passed in. The cluster (created earlier) is already attached to the
# regional endpoint by Atlas, so for the reuse case the data source below already sees the -pri host.
locals {
  effective_endpoint_id = var.create_private_endpoint ? aws_vpc_endpoint.atlas[0].id : var.existing_vpc_endpoint_id
}

# Re-read the cluster after the private endpoint is established. The cluster resource captures
# connection_strings at create time (before any endpoint exists) and is not re-read later in
# the same apply, so its private_endpoint list stays empty on a fresh apply. This data source's
# depends_on defers it until the endpoint_service is live, so the -pri connection string is
# populated within a single `terraform apply` (no second apply needed). When reusing an existing
# endpoint (count = 0) the depends_on is an empty list (a no-op) and the host already resolves.
data "mongodbatlas_advanced_cluster" "this" {
  project_id = var.project_id
  name       = mongodbatlas_advanced_cluster.this.name

  depends_on = [mongodbatlas_privatelink_endpoint_service.this]
}
