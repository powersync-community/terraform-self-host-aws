# Monitoring a self-hosted PowerSync deployment

Guides: [main infra guide](../../README.md) · [repo root](../../../README.md)

This module adds metrics, dashboards, logs, and alerts to the PowerSync service that the rest of this repo deploys on ECS Fargate. This file describes what the module actually builds, how to turn it on, what it costs, and where to look once it is running.

## What you get

Turn the stack on and you get one Grafana workspace with a curated dashboard covering PowerSync replication, client sync, storage, and the AWS infrastructure underneath (ECS and the load balancer). All PowerSync Prometheus metrics land in Amazon Managed Prometheus. Grafana shows recent logs through CloudWatch Logs Insights; when OpenSearch is enabled, task logs also become full-text searchable in the native OpenSearch Dashboards. A set of alerts watches replication health, API availability, error rates, and capacity, and every alert that fires is recorded as JSON in CloudWatch with optional forwarding to Slack or a webhook. Resource names are prefixed with the deployment name (`<deployment>-grafana`, `<deployment>-metrics`, `<deployment>-logs`, and so on), so several deployments can coexist in one account.

## Enabling it

Two flags in `infra/locals.tf` control the whole stack.

- `enable_observability` (master toggle). When `true`, the module creates the Amazon Managed Prometheus workspace, the Amazon Managed Grafana workspace with its two datasources and dashboard, the AMP recording and alerting rules, the SNS alert topic, and the alert-forwarder Lambda. It also switches the `api` and `replication` ECS tasks to run an ADOT collector sidecar that scrapes the PowerSync metrics endpoint. When `false`, the module creates nothing, and the `api` task runs a CloudWatch agent (cw-agent) sidecar instead. That sidecar publishes a single metric, `powersync_concurrent_connections`, to CloudWatch so the API service can still autoscale. Nothing else is collected in that mode.
- `enable_opensearch` (sub-toggle, effective only when `enable_observability` is also `true`). When `true`, it creates the OpenSearch domain, the log pipeline that feeds it, and the two OpenSearch health alarms. That buys full-text log search, aggregations, and longer retention in the native OpenSearch Dashboards (the `opensearch_dashboards_url` output). When `false`, none of that is created. Either way, Grafana's log rows read from CloudWatch Logs Insights, so logs stay visible in Grafana without the OpenSearch cluster. Grafana does not query OpenSearch directly, because Amazon Managed Grafana does not install the OpenSearch datasource plugin.

After changing the flags, run `terraform plan` and apply it. The module wires everything as code, so there are no console steps to finish the setup.

## Cost

OpenSearch is the only piece that runs an always-on cluster bill: a per-node-hour plus EBS charge, on the order of tens of dollars a month for the single small node this module provisions by default (`t3.small.search`, 20 GB gp3), and more if you scale it out.

The rest is priced by use, not by a fixed cluster. Amazon Managed Prometheus bills per ingested sample, and this deployment emits roughly a dozen series, so it stays in the cents. Amazon Managed Grafana bills per user who signs in during the month ($9 per editor, $5 per viewer), so it is $0 in a month nobody signs in and a few dollars per active user otherwise. SNS and the Lambdas are per-use and negligible.

Setting `enable_opensearch = false` removes the only always-on cluster while keeping metrics, dashboards, and alerts. What remains is Prometheus in the cents plus Grafana priced per active user. OpenSearch buys deep log search, native Dashboards, and longer log retention.

## Architecture (as built)

```
 api task ─┐                              ┌─ remote_write (SigV4) ─► Amazon Managed Prometheus
           ├─ ADOT collector sidecar ─────┤
repl task ─┘   (scrapes :9090/metrics)    └─ EMF: concurrent_connections ─► CloudWatch  (api task only)

ECS task log groups ─► CloudWatch Logs subscription filter ─► indexer Lambda ─► OpenSearch

Amazon Managed Grafana  ◄── AMP  ◄── CloudWatch  ◄── OpenSearch   (three datasources)

CloudWatch alarms ─┐                          ┌─ durable JSON log (always)
                   ├─► SNS topic ─► forwarder ─┤
AMP alert rules  ──┘         Lambda            └─ Slack / webhook (optional)
```

**Metrics.** Each PowerSync container exposes Prometheus metrics on port 9090 inside the task (never on a security group or the load balancer). An ADOT collector sidecar in the same task scrapes that endpoint every 30 seconds and remote-writes every `powersync_*` series to Amazon Managed Prometheus over a SigV4-signed connection. The collector adds `role` and `cluster` labels so panels and alerts can tell the `api` and `replication` processes apart. On the `api` task the same collector also emits one metric, `powersync_concurrent_connections`, to CloudWatch through its EMF exporter, in the exact namespace (`PowerSync`) and dimension (`ClusterName`) the autoscaling policy reads. The replicator collector has no CloudWatch path because the replicator publishes no autoscaling metric.

**Logs.** The PowerSync containers keep writing to their CloudWatch log groups (`/ecs/<deployment>-api`, `-replication`, `-compact`) through the standard `awslogs` driver. When OpenSearch is on, a subscription filter on each log group forwards batches to an indexer Lambda (`cwl-to-opensearch.mjs`, zero-dependency Node ESM). The Lambda gunzips each batch, turns every log line into one document (parsing JSON lines so fields like `level` and `logger` become searchable), and bulk-indexes into daily `powersync-logs-YYYY.MM.DD` indices over a SigV4-signed request. The Lambda's IAM role is mapped to an OpenSearch write role through fine-grained access control. Failed asynchronous invocations land in an SQS dead-letter queue with 14-day retention. The subscription filters and the invoke permission live in the ECS module, next to the log groups, to avoid a module cycle.

**Dashboards.** Amazon Managed Grafana runs one workspace authenticated through AWS IAM Identity Center. It has two datasources: Amazon Managed Prometheus (default, for PowerSync metrics) and CloudWatch (ECS and load-balancer metrics, plus the log rows through CloudWatch Logs Insights). A Terraform-managed service account provisions the datasources and the dashboard JSON as code. For deep OpenSearch log search, open the native OpenSearch Dashboards at the `opensearch_dashboards_url` output; Grafana does not query OpenSearch, because AMG does not install the OpenSearch datasource plugin.

Terraform renders the dashboard per deployment before importing it. It rewrites the committed `powersync-` prefix to your `deployment_name` so every log-group filter and CloudWatch dimension matches the real resources, and it appends the log rows (API and replicator error rates and recent-log tables) from `dashboards/cw-log-panels.json`, which query CloudWatch Logs Insights.

**Alerts.** Two sources publish to one SNS topic (`<deployment>-alerts`): CloudWatch alarms for the AWS infrastructure, and AMP Alertmanager rules for the PowerSync metrics. The Alertmanager emits a compact pipe-delimited line per alert so the forwarder can parse it without guessing at free text. A forwarder Lambda (`alert-logger.mjs`) subscribes to the topic. It writes every alert as a JSON line to its own CloudWatch log group, a durable record regardless of destination, and then, if you configured one, posts to Slack (formatted blocks) or a generic webhook. The SNS topic is the stable seam: change the destination without touching any alarm or rule. The webhook URL comes from Secrets Manager at runtime, supplied through the sensitive `TF_VAR_alert_webhook_url`, so no secret sits in code or function config.

## Metrics inventory

These are the PowerSync Prometheus metrics collected into Amazon Managed Prometheus. They are source-agnostic: the names and meanings are identical whether the source database is Postgres (RDS) or MongoDB (Atlas).

| Metric | Type | Process | Meaning |
|---|---|---|---|
| `powersync_replication_lag_seconds` | gauge | replicator | Lag between the source database and PowerSync. The primary health signal. |
| `powersync_rows_replicated_total` | counter | replicator | Rows pulled from the source. |
| `powersync_transactions_replicated_total` | counter | replicator | Source transactions applied. |
| `powersync_chunks_replicated_total` | counter | replicator | Replication chunks processed. |
| `powersync_data_replicated_bytes_total` | counter | replicator | Uncompressed bytes replicated from the source. |
| `powersync_replication_storage_size_bytes` | gauge | replicator | Current replication data size in bucket storage. |
| `powersync_operation_storage_size_bytes` | gauge | replicator | Operations data size in storage. |
| `powersync_parameter_storage_size_bytes` | gauge | replicator | Parameter-lookup data size in storage. |
| `powersync_concurrent_connections` | gauge | api | Active client sync connections. |
| `powersync_operations_synced_total` | counter | api | Operations sent to clients. |
| `powersync_data_synced_bytes_total` | counter | api | Uncompressed bytes synced to clients. |
| `powersync_data_sent_bytes_total` | counter | api | Bytes on the wire to clients, after compression. |

The module also defines AMP recording rules that materialize derived signals once, so dashboards and alerts reference the same named series: `powersync:replication_rate:rows5m`, `powersync:ops_synced:rate5m`, `powersync:compression:ratio5m`, `powersync:bytes_per_conn:5m`, `powersync:ops_per_row:5m`, and `powersync:param_bloat:ratio`.

## Dashboard

One dashboard, "PowerSync: Self-Hosted Overview", laid out top-down by what you check first. Its rows:

1. **Service health (SLOs).** At-a-glance stat tiles: current replication lag, replicator up, API healthy host count, concurrent connections, operations synced per second, and API 5xx rate.
2. **Replication pipeline.** Replication lag over time (by instance), rows/transactions/chunks replicated per second, data replicated bytes per second, and a count of replicator restarts.
3. **Client sync / API.** Concurrent connections over time, sync throughput (operations and bytes per second), compression ratio (bytes sent versus synced), bytes per connection, operations per row (sync-rule fan-out), sync connections that ended in an error or were rejected (by PowerSync error code), and all connection closes by outcome and reason. The two connection panels use `powersync_sync_connections_total`, which needs PowerSync Service 1.28.0 or later.
4. **Storage and capacity.** Stacked storage size (replication plus operation plus parameter bytes) and the parameter-storage bloat ratio. Watch the operation-storage line for a daily saw-tooth: a healthy nightly compaction makes it drop, and a flat-rising line means compaction is not reclaiming space.
5. **Infrastructure (ECS / ALB).** ECS CPU and memory utilization, API running task count, load-balancer request and 5xx counts, and target response time at p50, p90, and p99.
6. **Compaction.** Compaction emits no metrics (it is a short-lived CLI job), so this row is logs-first: successful-run and launch-failure counts, a runs-over-time view, and the raw compaction log panel.
7. **Errors.** Error rate by level for the API and replicator, from CloudWatch Logs Insights. For richer error breakdowns (auth failures, PSYNC codes, replication signals) use the native OpenSearch Dashboards when OpenSearch is enabled.
8. **Logs.** Recent-log tables for the API and replicator, from CloudWatch Logs Insights.

## Alerts

### AMP alert rules (PowerSync metrics)

| Alert | Condition | For | Severity |
|---|---|---|---|
| `PowerSyncReplicatorDown` | `absent(powersync_replication_lag_seconds)` | 5m | critical |
| `PowerSyncReplicationLagCritical` | `max(powersync_replication_lag_seconds) > 300` | 5m | critical |
| `PowerSyncReplicationLagHigh` | `max(powersync_replication_lag_seconds) > 60` | 5m | warning |
| `PowerSyncParameterStorageBloat` | `powersync:param_bloat:ratio > 0.5` | 30m | warning |
| `PowerSyncSyncConnectionErrors` | `sum(increase(powersync_sync_connections_total{outcome=~"error\|rejected"}[5m])) > 10` | 10m | warning |

The parameter-bloat rule fires when parameter storage passes 50% of data storage, a precursor to checksum timeouts.

The sync-connection rule fires when more than 10 sync connections in 5 minutes end in a stream error or are rejected. It needs PowerSync Service 1.28.0 or later. The series appears only after the first error, so the rule stays silent until then. Treat 10 as a starting point and tune it to your normal background rate. The dashboard panel shows which [error code](https://docs.powersync.com/debugging/error-codes) is behind the alert.

### CloudWatch alarms (infrastructure)

| Alarm | Metric | Condition |
|---|---|---|
| `<deployment>-compaction-launch-failed` | `AWS/Events` `FailedInvocations` for the daily compact rule | Sum >= 1 over a 24h period |
| `<deployment>-api-no-healthy-hosts` | `AWS/ApplicationELB` `HealthyHostCount` | Minimum < 1 for 3 minutes (missing data treated as breaching) |
| `<deployment>-api-target-5xx` | `AWS/ApplicationELB` `HTTPCode_Target_5XX_Count` | Sum > 10 in 5 minutes |
| `<deployment>-api-cpu-high` | `AWS/ECS` `CPUUtilization` | Average > 85% for 15 minutes |
| `<deployment>-opensearch-cluster-red` | `AWS/ES` `ClusterStatus.red` | Maximum >= 1 over 5 minutes |
| `<deployment>-opensearch-low-storage` | `AWS/ES` `FreeStorageSpace` | Minimum < 2 GB (2048 MB) over 5 minutes |

The two OpenSearch alarms exist only when `enable_opensearch` is on. The compaction, no-healthy-hosts, and OpenSearch alarms send both alarm and recovery notifications; the 5xx and CPU alarms notify on alarm only.

## Accessing it

Read the endpoints from Terraform outputs at the repo's infra root:

- `terraform output grafana_workspace_url` gives the Grafana workspace URL. Grafana signs in through AWS IAM Identity Center. Assign yourself a role in the Grafana console, or set `grafana_admin_user_id` in the config to grant ADMIN to a specific Identity Center user at apply time.
- `terraform output opensearch_dashboards_url` gives the native OpenSearch Dashboards URL (present only when `enable_opensearch` is on). Log in with the master user and password from `terraform output opensearch_master_user` and `terraform output -raw opensearch_master_password`.

## A note on the source database

This repo's default deployment uses Postgres on RDS. The PowerSync-layer panels (dashboard rows 1 through 4) and every PowerSync metric and alert above are identical on a MongoDB (Atlas) source, because those metrics are computed by PowerSync from its own replication position rather than from the source engine. What differs by source is the source-database infrastructure metrics and the specific log vocabulary of replication failures, neither of which the PowerSync-layer panels depend on.
