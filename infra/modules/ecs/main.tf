locals {
  cluster_name       = "${var.name_prefix}-cluster"
  api_family         = "${var.name_prefix}-api"
  replication_family = "${var.name_prefix}-replication"
  compact_family     = "${var.name_prefix}-compact"
  api_container      = "${var.name_prefix}-api"
  replication_cont   = "${var.name_prefix}-replication"
  compact_container  = "${var.name_prefix}-compact"
  cwagent_container  = "cloudwatch-agent"

  # Log groups (explicit, with retention — NOT awslogs-create-group, which orphans groups on
  # destroy and races on re-apply). The prometheus group name is also hardcoded in
  # config/cw-agent-config.json; if you change name_prefix, update that file's log_group_name.
  lg_replication = "/ecs/${var.name_prefix}-replication"
  lg_api         = "/ecs/${var.name_prefix}-api"
  lg_api_cwagent = "/ecs/${var.name_prefix}-api/cwagent"
  lg_api_prom    = "/ecs/${var.name_prefix}-api/prometheus"
  lg_compact     = "/ecs/${var.name_prefix}-compact"

  prometheus_config_content = <<-EOT
    global:
      scrape_interval: 30s
      scrape_timeout: 10s
    scrape_configs:
      - job_name: powersync
        static_configs:
          - targets:
              - localhost:${var.prometheus_port}
  EOT
}

###############################################################################
# Observability sidecar — the api task runs exactly one metrics sidecar:
# the ADOT collector when enable_observability is true, the cw-agent otherwise.
###############################################################################

locals {
  # ADOT collector config, passed inline via AOT_CONFIG_CONTENT. It scrapes the
  # in-task prometheus endpoint and fans the metrics out to two exporters:
  #   - prometheusremotewrite -> AMP (all powersync_* metrics, SigV4-signed)
  #   - awsemf -> CloudWatch, ONLY powersync_concurrent_connections, which the
  #     autoscaling policy reads as PowerSync/powersync_concurrent_connections.
  # relabel_configs stamp cluster / powersync_role / ClusterName onto every series.
  # The awsemf metric is emitted with BOTH the ClusterName dimension and no dimensions
  # ([["ClusterName"], []]) so it resolves whether the autoscaling policy queries the
  # metric with or without a dimension.
  otel_config = <<-EOT
    extensions:
      sigv4auth:
        region: ${var.region}
        service: aps
    receivers:
      prometheus:
        config:
          global:
            scrape_interval: 30s
            scrape_timeout: 10s
          scrape_configs:
            - job_name: powersync
              static_configs:
                - targets: ['localhost:${var.prometheus_port}']
              relabel_configs:
                - target_label: cluster
                  replacement: ${local.cluster_name}
                - target_label: powersync_role
                  replacement: api
                - target_label: ClusterName
                  replacement: ${local.cluster_name}
    processors:
      batch: {}
    exporters:
      prometheusremotewrite:
        endpoint: ${var.amp_remote_write_url}
        auth:
          authenticator: sigv4auth
      awsemf:
        region: ${var.region}
        namespace: PowerSync
        log_group_name: ${local.lg_api_prom}
        dimension_rollup_option: NoDimensionRollup
        metric_declarations:
          - dimensions: [["ClusterName"], []]
            metric_name_selectors:
              - "^powersync_concurrent_connections$"
    service:
      extensions: [sigv4auth]
      telemetry:
        logs:
          level: warn
      pipelines:
        metrics/amp:
          receivers: [prometheus]
          processors: [batch]
          exporters: [prometheusremotewrite]
        metrics/cloudwatch:
          receivers: [prometheus]
          processors: [batch]
          exporters: [awsemf]
  EOT

  # ADOT collector sidecar (used when enable_observability).
  adot_sidecar = {
    name      = "aws-otel-collector"
    image     = "public.ecr.aws/aws-observability/aws-otel-collector:latest"
    essential = false
    memory    = 256
    environment = [
      { name = "AOT_CONFIG_CONTENT", value = local.otel_config },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = local.lg_api_cwagent
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }

  # cw-agent sidecar (used when observability is disabled): scrapes the prometheus
  # endpoint and publishes powersync_concurrent_connections to CloudWatch via EMF.
  cwagent_sidecar = {
    name      = local.cwagent_container
    image     = "public.ecr.aws/cloudwatch-agent/cloudwatch-agent:latest"
    essential = false
    memory    = 256
    environment = [
      { name = "PROMETHEUS_CONFIG_CONTENT", value = local.prometheus_config_content },
    ]
    secrets = [
      { name = "CW_CONFIG_CONTENT", valueFrom = var.cwagent_param_arn },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = local.lg_api_cwagent
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }

  # The api application container (process: start -r api). Paired with one metrics sidecar
  # in the api task definition below.
  api_app_container = {
    name      = local.api_container
    image     = var.image
    command   = ["start", "-r", "api"]
    essential = true
    portMappings = [
      { containerPort = 8080, protocol = "tcp" },
    ]
    environment = [
      { name = "PS_PORT", value = "8080" },
      { name = "NODE_OPTIONS", value = var.api_node_options },
    ]
    # Least-privilege: the api task reads the api-specific config (restricted storage user).
    secrets = [
      { name = "POWERSYNC_CONFIG_B64", valueFrom = var.api_config_secret_prefix_arn },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = local.lg_api
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }
    healthCheck = {
      # The powersync-service image is node:slim — it has NO curl/wget. Use node's global
      # fetch (node 22) for the probe; a curl-based check fails forever and cycles the task.
      command     = ["CMD-SHELL", "node -e 'fetch(\"http://localhost:8080/probes/liveness\").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))'"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
    stopTimeout = var.stop_timeout
  }

  # Replication ADOT sidecar config — remote-write to AMP only. The replicator publishes no
  # autoscaling metric, so there is no awsemf/CloudWatch path (unlike the api collector).
  # powersync_role=replication distinguishes its series (replication lag, storage sizes,
  # rows/transactions/chunks) from the api task's in AMP.
  otel_config_replication = <<-EOT
    extensions:
      sigv4auth:
        region: ${var.region}
        service: aps
    receivers:
      prometheus:
        config:
          global:
            scrape_interval: 30s
            scrape_timeout: 10s
          scrape_configs:
            - job_name: powersync
              static_configs:
                - targets: ['localhost:${var.prometheus_port}']
              relabel_configs:
                - target_label: cluster
                  replacement: ${local.cluster_name}
                - target_label: powersync_role
                  replacement: replication
    processors:
      batch: {}
    exporters:
      prometheusremotewrite:
        endpoint: ${var.amp_remote_write_url}
        auth:
          authenticator: sigv4auth
    service:
      extensions: [sigv4auth]
      telemetry:
        logs:
          level: warn
      pipelines:
        metrics/amp:
          receivers: [prometheus]
          processors: [batch]
          exporters: [prometheusremotewrite]
  EOT

  # Replication ADOT sidecar (used when enable_observability). Logs to the replicator's log
  # group under the "otel" stream prefix, keeping them distinct from the app's "ecs" stream.
  adot_sidecar_replication = {
    name      = "aws-otel-collector"
    image     = "public.ecr.aws/aws-observability/aws-otel-collector:latest"
    essential = false
    memory    = 256
    environment = [
      { name = "AOT_CONFIG_CONTENT", value = local.otel_config_replication },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = local.lg_replication
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "otel"
      }
    }
  }

  # The replication application container (process: start -r sync). Runs alone, or paired with
  # the ADOT sidecar when observability is enabled.
  replication_app_container = {
    name      = local.replication_cont
    image     = var.image
    command   = ["start", "-r", "sync"]
    essential = true
    environment = [
      { name = "NODE_OPTIONS", value = var.replication_node_options },
    ]
    secrets = [
      { name = "POWERSYNC_CONFIG_B64", valueFrom = var.config_secret_prefix_arn },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = local.lg_replication
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }
}

###############################################################################
# Log groups
###############################################################################

resource "aws_cloudwatch_log_group" "replication" {
  name              = local.lg_replication
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "api" {
  name              = local.lg_api
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "api_cwagent" {
  name              = local.lg_api_cwagent
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "api_prometheus" {
  name              = local.lg_api_prom
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "compact" {
  name              = local.lg_compact
  retention_in_days = var.log_retention_days
}

# Ship the app log groups (api / replication / compact) to the log-indexer Lambda ->
# OpenSearch when enabled. Subscription filters target a Lambda via a resource-based
# invoke permission (no PassRole). Kept here next to the groups (not in observability)
# to avoid an ecs<->observability cycle.
locals {
  os_app_log_groups = var.enable_opensearch ? {
    api         = aws_cloudwatch_log_group.api
    replication = aws_cloudwatch_log_group.replication
    compact     = aws_cloudwatch_log_group.compact
  } : {}
}

resource "aws_lambda_permission" "cwl_invoke" {
  for_each = local.os_app_log_groups

  statement_id  = "AllowCWL-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = var.log_lambda_function_name
  principal     = "logs.${var.region}.amazonaws.com"
  source_arn    = "${each.value.arn}:*"
}

resource "aws_cloudwatch_log_subscription_filter" "to_opensearch" {
  for_each = local.os_app_log_groups

  name            = "${var.name_prefix}-to-opensearch"
  log_group_name  = each.value.name
  filter_pattern  = ""
  destination_arn = var.log_lambda_arn

  # The invoke permission must exist before CloudWatch Logs will accept the filter.
  depends_on = [aws_lambda_permission.cwl_invoke]
}

###############################################################################
# Cluster
###############################################################################

resource "aws_ecs_cluster" "this" {
  name = local.cluster_name

  # Container Insights publishes ECS/ContainerInsights metrics (RunningTaskCount, etc.);
  # enabled with observability, off otherwise to avoid its per-metric cost.
  setting {
    name  = "containerInsights"
    value = var.enable_observability ? "enabled" : "disabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

###############################################################################
# Replication task definition — single active replicator (start -r sync)
###############################################################################

resource "aws_ecs_task_definition" "replication" {
  family                   = local.replication_family
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.replication_cpu)
  memory                   = tostring(var.replication_memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  # Replication app container alone, or paired with the ADOT sidecar when observability is on.
  # Selected as a rendered JSON string so the one- and two-container shapes don't collide in a
  # single ternary (same reasoning as the api task definition).
  container_definitions = var.enable_observability ? jsonencode([local.replication_app_container, local.adot_sidecar_replication]) : jsonencode([local.replication_app_container])
}

###############################################################################
# API task definition — API process (start -r api) + cw-agent sidecar
###############################################################################

resource "aws_ecs_task_definition" "api" {
  family                   = local.api_family
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.api_cpu)
  memory                   = tostring(var.api_memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  # A task definition is a tuple of heterogeneous container objects, so the app container and
  # its sidecar can have different shapes. The metrics sidecar differs by mode, so the whole
  # definition is selected as a rendered JSON string (the cw-agent sidecar carries a `secrets`
  # block the ADOT one does not, which a single ternary over objects would reject).
  container_definitions = var.enable_observability ? jsonencode([local.api_app_container, local.adot_sidecar]) : jsonencode([local.api_app_container, local.cwagent_sidecar])
}

###############################################################################
# Compact task definition — scheduled bucket compaction (command: compact)
###############################################################################

resource "aws_ecs_task_definition" "compact" {
  family                   = local.compact_family
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.compact_cpu)
  memory                   = tostring(var.compact_memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([
    {
      name      = local.compact_container
      image     = var.image
      command   = ["compact"]
      essential = true
      environment = [
        { name = "NODE_OPTIONS", value = var.compact_node_options },
      ]
      secrets = [
        { name = "POWERSYNC_CONFIG_B64", valueFrom = var.config_secret_prefix_arn },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = local.lg_compact
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

###############################################################################
# Replication service — desired 1, no LB. min_healthy=0/max=100 so the single
# replicator (which holds the sync-rule lock) can be replaced. This causes a brief
# replication gap on every deploy: the old task stops before the new one is healthy.
###############################################################################

resource "aws_ecs_service" "replication" {
  name            = local.replication_family
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.replication.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_sg_id]
    assign_public_ip = false
  }
}

###############################################################################
# API service — behind the ALB, zero-downtime rolling (min_healthy=100/max=200),
# autoscaler owns desired_count.
###############################################################################

resource "aws_ecs_service" "api" {
  name            = local.api_family
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.api_min_capacity
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = var.health_check_grace

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = local.api_container
    container_port   = 8080
  }

  # The autoscaler owns the running count; don't let TF revert it on apply.
  lifecycle {
    ignore_changes = [desired_count]
  }
}

###############################################################################
# Autoscaling — CPU @ cpu_target and custom connections @ connection_target.
# Scale-out goes to whichever policy demands more tasks; scale-in only when both agree.
###############################################################################

resource "aws_appautoscaling_target" "api" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.api_min_capacity
  max_capacity       = var.api_max_capacity
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name_prefix}-cpu-scaling"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target
    scale_in_cooldown  = var.scale_in_cooldown
    scale_out_cooldown = var.scale_out_cooldown

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "connections" {
  name               = "${var.name_prefix}-connection-scaling"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    target_value       = var.connection_target
    scale_in_cooldown  = var.scale_in_cooldown
    scale_out_cooldown = var.scale_out_cooldown

    # The cw-agent publishes powersync_concurrent_connections dimensioned only by
    # ClusterName (no per-task dimension). Statistic = Average therefore means
    # "average connections per task" — Sum would be wrong by a factor of N (task count).
    # The dimensions block MUST match the series the agent writes (ClusterName=<cluster>):
    # omitting it makes the target-tracking alarm watch a dimensionless series that never
    # has data, so the alarm sits in INSUFFICIENT_DATA and this policy never scales.
    customized_metric_specification {
      metric_name = "powersync_concurrent_connections"
      namespace   = "PowerSync"
      statistic   = "Average"

      dimensions {
        name  = "ClusterName"
        value = aws_ecs_cluster.this.name
      }
    }
  }
}

###############################################################################
# Daily compact job — EventBridge RunTask in the private subnets.
###############################################################################

resource "aws_cloudwatch_event_rule" "compact" {
  name                = "${var.name_prefix}-compact-daily"
  schedule_expression = var.compact_schedule
}

resource "aws_cloudwatch_event_target" "compact" {
  rule     = aws_cloudwatch_event_rule.compact.name
  arn      = aws_ecs_cluster.this.arn
  role_arn = var.events_role_arn

  ecs_target {
    task_definition_arn = aws_ecs_task_definition.compact.arn
    task_count          = 1
    launch_type         = "FARGATE"

    network_configuration {
      subnets          = var.private_subnet_ids
      security_groups  = [var.ecs_sg_id]
      assign_public_ip = false
    }
  }
}
