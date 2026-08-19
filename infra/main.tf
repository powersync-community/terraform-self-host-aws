data "aws_caller_identity" "current" {}

###############################################################################
# Guards — fail the plan early on a wrong account or an illegal Fargate CPU/memory pair.
###############################################################################

resource "terraform_data" "guards" {
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.account_id
      error_message = "Active AWS credentials resolve to a different account than var.account_id. Aborting to avoid deploying into the wrong account."
    }
    precondition {
      condition     = contains(lookup(local.valid_fargate, tostring(local.api_cpu), []), local.api_memory)
      error_message = "api_cpu/api_memory is not a legal Fargate combination."
    }
    precondition {
      condition     = contains(lookup(local.valid_fargate, tostring(local.replication_cpu), []), local.replication_memory)
      error_message = "replication_cpu/replication_memory is not a legal Fargate combination."
    }
    precondition {
      condition     = contains(lookup(local.valid_fargate, tostring(local.compact_cpu), []), local.compact_memory)
      error_message = "compact_cpu/compact_memory is not a legal Fargate combination."
    }
  }
}

###############################################################################
# Modules
###############################################################################

module "network" {
  source = "./modules/network"

  name_prefix          = local.name_prefix
  vpc_cidr             = "10.20.0.0/16"
  public_subnet_cidrs  = ["10.20.0.0/20", "10.20.16.0/20"]   # one /20 per AZ (ALB + NAT + RDS)
  private_subnet_cidrs = ["10.20.96.0/20", "10.20.112.0/20"] # one /20 per AZ (ECS tasks)
}

# Source + bucket-storage database. One RDS Postgres instance hosts both databases (the source
# `app` database created by the module, and the `powersync` storage database created in
# database.tf). Reachable by the ECS tasks and, for local seeding, from var.admin_cidr.
module "rds" {
  source = "./modules/rds"

  name_prefix       = local.name_prefix
  vpc_id            = module.network.vpc_id
  subnet_ids        = module.network.public_subnet_ids
  ecs_sg_id         = module.network.ecs_sg_id
  admin_cidr        = var.admin_cidr
  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  engine_version    = var.postgres_version
  source_db_name    = local.source_db
}

####################################################################################################
# OPTIONAL: MongoDB Atlas instead of RDS.
#
# This repo keeps modules/atlas-cluster as a worked example of using MongoDB Atlas (over AWS
# PrivateLink) as the source + bucket-storage database. To use it instead of RDS you would:
#   1. Uncomment the mongodbatlas provider (providers.tf), its required_providers (versions.tf),
#      and the atlas_* variables (variables.tf).
#   2. Uncomment the two module blocks below, remove the module.rds block above, and rewire the
#      Postgres locals in locals.tf to the Atlas mongodb+srv URIs (see git history for the shape).
#   3. Re-add the Atlas PrivateLink security group to modules/network.
#
# IMPORTANT — the deployment_name prefix does NOT give you isolated multi-deployment on Atlas the
# way it does on RDS. Atlas allows only ONE PrivateLink endpoint service per region per project,
# and a cluster's private endpoint is shared across the region/project. So two Atlas-backed
# deployments in the SAME Atlas project and region cannot each stand up their own private endpoint
# — give each deployment its own Atlas project (or region) if you need them side by side. (RDS has
# no such limit, which is why it is the default here.)
#
# module "atlas" {
#   source = "./modules/atlas-cluster"
#
#   project_id  = var.atlas_project_id
#   name_prefix = local.name_prefix          # deployment_name still prefixes the Atlas cluster/user names
#   region_name = "US_EAST_1"
#
#   vpc_id             = module.network.vpc_id
#   private_subnet_ids = module.network.private_subnet_ids
#   endpoint_sg_id     = module.network.atlas_endpoint_sg_id # re-add this SG to modules/network
# }
#
# module "atlas_storage" {
#   source = "./modules/atlas-cluster"
#
#   project_id    = var.atlas_project_id
#   name_prefix   = "${local.name_prefix}-storage"
#   region_name   = "US_EAST_1"
#   instance_size = "M10"
#
#   # Reuse the single regional PrivateLink endpoint created by module.atlas (see IMPORTANT note above).
#   create_private_endpoint  = false
#   existing_vpc_endpoint_id = module.atlas.vpc_endpoint_id
#
#   vpc_id             = module.network.vpc_id
#   private_subnet_ids = module.network.private_subnet_ids
#   endpoint_sg_id     = module.network.atlas_endpoint_sg_id
# }
####################################################################################################

module "alb" {
  source = "./modules/alb"

  name_prefix          = local.name_prefix
  vpc_id               = module.network.vpc_id
  public_subnet_ids    = module.network.public_subnet_ids
  alb_sg_id            = module.network.alb_sg_id
  domain               = local.domain
  route53_zone_id      = var.route53_zone_id
  idle_timeout         = 3600 # long-lived sync websockets need this well above the 60s default
  deregistration_delay = 300  # connection-drain delay (seconds) on scale-in
  jwks_json            = local.jwks_json
}

module "secrets" {
  source = "./modules/secrets"

  config_secret_name     = local.config_secret_name
  config_b64             = local.config_b64
  config_api_secret_name = local.config_api_secret_name
  config_api_b64         = local.config_api_b64
  cwagent_param_name     = local.cwagent_param_name
  cwagent_config         = local.cwagent_config
}

module "observability" {
  source = "./modules/observability"

  name_prefix          = local.name_prefix
  enable_observability = local.enable_observability

  grafana_role_arn      = module.iam.grafana_role_arn
  grafana_admin_user_id = var.grafana_admin_user_id

  enable_opensearch   = local.enable_opensearch
  region              = local.region
  account_id          = var.account_id
  log_lambda_role_arn = module.iam.log_lambda_role_arn

  alert_lambda_role_arn   = module.iam.alert_lambda_role_arn
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix

  alert_destination = var.alert_destination
  alert_webhook_url = var.alert_webhook_url
  dashboard_uid     = jsondecode(file("${path.module}/dashboards/powersync-overview.json")).uid
}

module "iam" {
  source = "./modules/iam"

  name_prefix              = local.name_prefix
  region                   = local.region
  account_id               = var.account_id
  create_iam_roles         = true
  permissions_boundary_arn = local.iam_permissions_boundary_arn

  enable_observability = local.enable_observability
  enable_opensearch    = local.enable_opensearch
  enable_alert_webhook = local.enable_alert_webhook
}

module "ecs" {
  source = "./modules/ecs"

  name_prefix        = local.name_prefix
  region             = local.region
  image              = local.image
  log_retention_days = 14

  private_subnet_ids = module.network.private_subnet_ids
  ecs_sg_id          = module.network.ecs_sg_id
  target_group_arn   = module.alb.target_group_arn

  execution_role_arn = module.iam.execution_role_arn
  task_role_arn      = module.iam.task_role_arn
  events_role_arn    = module.iam.events_role_arn

  config_secret_prefix_arn     = local.config_secret_prefix_arn
  api_config_secret_prefix_arn = local.config_api_secret_prefix_arn
  cwagent_param_arn            = local.cwagent_param_arn
  prometheus_port              = local.prometheus_port

  enable_observability = local.enable_observability
  amp_remote_write_url = module.observability.amp_remote_write_url

  enable_opensearch        = local.enable_opensearch
  log_lambda_arn           = module.observability.log_lambda_arn
  log_lambda_function_name = module.observability.log_lambda_function_name

  api_cpu          = local.api_cpu
  api_memory       = local.api_memory
  api_node_options = local.api_node_options

  replication_cpu          = local.replication_cpu
  replication_memory       = local.replication_memory
  replication_node_options = local.replication_node_options

  compact_cpu          = local.compact_cpu
  compact_memory       = local.compact_memory
  compact_node_options = local.compact_node_options
  compact_schedule     = "cron(0 2 * * ? *)" # daily compact job, 02:00 UTC

  # Autoscaling — tuned for ~500 concurrent connections.
  api_min_capacity   = 2 # HA floor
  api_max_capacity   = 8 # ceil(500/80)=7 at peak + 1 task of headroom
  connection_target  = floor(local.ps_max_concurrent_connections * 0.4)
  cpu_target         = 70  # target avg CPU utilization (%)
  scale_out_cooldown = 120 # new Fargate tasks take 1-3 min to become ready
  scale_in_cooldown  = 300 # conservative — avoid reconnection oscillation

  health_check_grace = 120 # ECS service health-check grace period (seconds)
  stop_timeout       = 120 # container stopTimeout — graceful sync drain before SIGKILL

  # Config secret + cw-agent param must exist before the tasks start.
  depends_on = [module.secrets]
}
