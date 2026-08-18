locals {
  # --- High-level naming config ---
  region      = "us-east-1"
  name_prefix = var.deployment_name # prefixes every resource -> <name>-cluster, <name>/config, etc.

  # ALB is published here. Deriving the host from deployment_name keeps each deployment on its
  # own subdomain automatically (a PowerSync API must have its own dedicated subdomain).
  domain = "${var.deployment_name}.${var.base_domain}"

  common_tags = {
    Project     = "powersync-hosting-example"
    ManagedBy   = "terraform"
    Environment = "demo"
    Deployment  = var.deployment_name
  }

  # Opt-in observability. When true: creates an Amazon Managed Prometheus workspace and runs
  # an ADOT collector sidecar on the api task that remote-writes metrics to AMP and publishes
  # powersync_concurrent_connections to CloudWatch for autoscaling. When false: no observability
  # resources are created and the api task uses the cw-agent sidecar to publish the autoscaling metric.
  enable_observability = true

  # Sub-toggle for the OpenSearch log pipeline (the costly always-on piece). Takes effect only
  # when enable_observability is also true.
  enable_opensearch = true

  # Alert forwarding beyond the durable log. Needs a destination other than "log" and a webhook URL.
  enable_alert_webhook = local.enable_observability && var.alert_destination != "log" && var.alert_webhook_url != ""

  # Optional IAM permissions boundary attached to every role created here. null = omit (the common
  # case). Set var.iam_permissions_boundary only if your account requires one.
  iam_permissions_boundary_arn = var.iam_permissions_boundary == "" ? null : "arn:aws:iam::${var.account_id}:policy/${var.iam_permissions_boundary}"

  # Full image reference shared by all three task definitions — the official public PowerSync
  # service image, pulled directly (no per-account ECR mirror needed).
  image = "journeyapps/powersync-service:1.22.0"

  # Task sizing (Fargate CPU units / MiB). Kept here (not inline) because each pair feeds both
  # the Fargate guard in main.tf and the NODE_OPTIONS math below.
  api_cpu            = 1024
  api_memory         = 2048
  replication_cpu    = 2048
  replication_memory = 4096
  compact_cpu        = 1024
  compact_memory     = 2048

  # Prometheus telemetry port — scraped by the sidecar and written into the rendered service.yaml.
  # Stays internal to the task; never on a security group or the ALB.
  prometheus_port = 9090

  # --- Per-task PowerSync sync concurrency (api.parameters in service.yaml.tftpl) ---
  # Both default in the image (200 / 10); pinned here so the ceilings are version-stable and the
  # connection autoscaler (connection_target in main.tf) derives from a real number.
  ps_max_concurrent_connections = 200 # HTTP sync-stream admission; connection (this+1) -> instant 429.
  ps_max_data_fetch_concurrency = 20  # concurrent bucket-data fetch slots per task (image default 10).

  # Secret + SSM paths. Kept in sync with the IAM wildcard policies (<name_prefix>/*).
  config_secret_name     = "${local.name_prefix}/config"
  config_api_secret_name = "${local.name_prefix}/config-api"
  cwagent_param_name     = "/ecs/${local.name_prefix}/cwagent-config"

  # PREFIX ARNs (no 6-char Secrets Manager suffix). Task definitions reference secrets by prefix so
  # a rotation that changes the suffix does not require re-registering the task def.
  config_secret_prefix_arn     = "arn:aws:secretsmanager:${local.region}:${var.account_id}:secret:${local.config_secret_name}"
  config_api_secret_prefix_arn = "arn:aws:secretsmanager:${local.region}:${var.account_id}:secret:${local.config_api_secret_name}"
  cwagent_param_arn            = "arn:aws:ssm:${local.region}:${var.account_id}:parameter${local.cwagent_param_name}"

  # NODE_OPTIONS — use the ABSOLUTE --max-old-space-size (MiB). floor(mem*0.8) leaves headroom for
  # the runtime and sidecars while giving Node most of the task memory.
  api_node_options         = "--max-old-space-size=${floor(local.api_memory * 0.8)}"
  replication_node_options = "--max-old-space-size=${floor(local.replication_memory * 0.8)}"
  compact_node_options     = "--max-old-space-size=${floor(local.compact_memory * 0.8)}"

  # --- Postgres (RDS) connection wiring ---
  # One RDS instance hosts BOTH the source database and the bucket-storage database (separate
  # databases; supported on Postgres 14+). Two least-privilege roles, created by the bootstrap in
  # database.tf: a source/replication role and a storage role. Passwords are generated (database.tf).
  # sslmode=verify-full validates the RDS server cert against the built-in AWS RDS CA (no cacert needed).
  pg_host      = module.rds.address
  pg_port      = module.rds.port
  source_db    = "app"       # source application data (the demo `lists` table)
  storage_db   = "powersync" # PowerSync bucket storage
  source_role  = "powersync_source"
  storage_role = "powersync_storage"

  source_uri  = "postgresql://${local.source_role}:${random_password.pg_source.result}@${local.pg_host}:${local.pg_port}/${local.source_db}?sslmode=verify-full"
  storage_uri = "postgresql://${local.storage_role}:${random_password.pg_storage.result}@${local.pg_host}:${local.pg_port}/${local.storage_db}?sslmode=verify-full"

  # JWKS endpoint PowerSync validates client tokens against — served by our own ALB (auth.tf
  # generates the keys; the ALB serves them at /api/auth/keys). Derived from the domain.
  jwks_uri = "https://${local.domain}/api/auth/keys"

  # Template vars for the rendered service config. The source connection + bucket storage are both
  # Postgres. The demo `lists` table is synced per-user via the JWT subject (request.user_id()).
  config_vars = {
    source_uri                 = local.source_uri
    storage_uri                = local.storage_uri
    jwks_url                   = local.jwks_uri
    jwt_audience               = ["powersync-dev", "authenticated"]                     # accepted JWT audiences for client auth
    api_tokens                 = var.admin_api_token == "" ? [] : [var.admin_api_token] # bearer token(s) for the admin/management API
    prometheus_port            = local.prometheus_port
    max_concurrent_connections = local.ps_max_concurrent_connections
    max_data_fetch_concurrency = local.ps_max_data_fetch_concurrency

    # Sync rules (Postgres). Each client syncs only the `lists` rows it owns, matched on the trusted
    # JWT subject via request.user_id(). Replace with your own tables/queries.
    sync_rules_content = <<-EOT
      bucket_definitions:
        by_user:
          parameters: SELECT request.user_id() as user_id
          data:
            - SELECT * FROM lists WHERE owner_id = bucket.user_id
    EOT
  }

  # Rendered service.yaml -> base64 -> the config secret. It carries the Postgres URIs (with
  # credentials) and the JWKS URL, so it lives only in the secret, never in a task definition.
  config_yaml = templatefile("${path.module}/config/service.yaml.tftpl", local.config_vars)
  config_b64  = base64encode(local.config_yaml)

  # The api task uses a separate secret purely so the two-secret plumbing stays in place; on
  # Postgres we use a single storage role, so the api config is identical to the main config.
  # (The Atlas example uses this seam for a stricter storage-api user — see modules/atlas-cluster.)
  config_api_b64 = local.config_b64

  # cw-agent EMF config (publishes powersync_concurrent_connections to the PowerSync namespace,
  # dimensioned by ClusterName). Templated so the log-group name tracks the deployment prefix.
  cwagent_config = templatefile("${path.module}/config/cw-agent-config.json.tftpl", {
    name_prefix = local.name_prefix
  })

  # Stable key id shared by the generated JWKS (auth.tf) and the example client's mint-token script.
  jwt_kid = "powersync-example"

  # Public JWKS served at https://<domain>/api/auth/keys via an ALB fixed-response rule.
  # jwks_from_key returns a SINGLE JWK; a jwks_uri must return a {"keys":[...]} set, so wrap it.
  jwks_json = jsonencode({ keys = [jsondecode(data.jwks_from_key.jwt.jwks)] })

  # AWS Fargate legal CPU -> allowed memory (MiB) matrix, used by the guard in main.tf.
  valid_fargate = {
    "256"   = [512, 1024, 2048]
    "512"   = [1024, 2048, 3072, 4096]
    "1024"  = [2048, 3072, 4096, 5120, 6144, 7168, 8192]
    "2048"  = [4096, 5120, 6144, 7168, 8192, 9216, 10240, 11264, 12288, 13312, 14336, 15360, 16384]
    "4096"  = [8192, 9216, 10240, 11264, 12288, 13312, 14336, 15360, 16384, 17408, 18432, 19456, 20480, 21504, 22528, 23552, 24576, 25600, 26624, 27648, 28672, 29696, 30720]
    "8192"  = [16384, 20480, 24576, 28672, 32768, 36864, 40960, 45056, 49152, 53248, 57344, 61440]
    "16384" = [32768, 40960, 49152, 57344, 65536, 73728, 81920, 90112, 98304, 106496, 114688, 122880]
  }
}
