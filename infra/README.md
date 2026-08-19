# PowerSync on AWS ECS (Terraform)

Provisions a self-hosted PowerSync deployment on AWS ECS Fargate with Amazon RDS for PostgreSQL as
both the source database and the sync bucket storage. One `terraform apply` builds the VPC, the RDS
instance, the ECS services, the ALB and TLS, and the client-auth signing key.

`var.deployment_name` prefixes every resource, so multiple deployments coexist in one AWS account and
region.

## Module layout

```
infra/
  versions.tf providers.tf variables.tf locals.tf main.tf outputs.tf auth.tf database.tf
  config/
    service.yaml.tftpl          # rendered -> base64 -> the config secret(s)
    cw-agent-config.json.tftpl  # EMF config for the autoscaling connection metric
  modules/
    network/        # VPC, public/private subnets, NAT, security groups
    rds/            # RDS Postgres instance, parameter group (logical replication), DB security group
    alb/            # ACM cert (DNS-validated), ALB, target group, HTTPS listener, Route 53 alias, JWKS
    secrets/        # the config + config-api secrets + cw-agent SSM parameter
    iam/            # execution / task / events roles (optional permissions boundary)
    ecs/            # cluster, task defs (replication / api / compact), services, autoscaling, schedule
    observability/  # (optional) AMP, Grafana, OpenSearch log pipeline, SNS + alert forwarder
    atlas-cluster/  # optional worked example: MongoDB Atlas instead of RDS (commented out in main.tf)
  auth.tf           # TF-generated RS256 JWT key -> Secrets Manager + the ALB-served JWKS
  database.tf       # generated passwords for the two least-privilege Postgres roles
```

## What apply creates

In dependency order:

- **Network:** VPC (`10.20.0.0/16`), 2 public + 2 private subnets, IGW, NAT, security groups.
- **RDS:** one PostgreSQL instance with `rds.logical_replication = 1`, holding the source database
  (`app`) and, after the bootstrap, the bucket-storage database (`powersync`). It is publicly
  accessible for the demo, with its security group limiting access to the ECS tasks and `var.admin_cidr`.
- **ALB:** a DNS-validated ACM certificate, the ALB, target group, HTTPS listener, a Route 53 alias
  at `<deployment_name>.<base_domain>`, and a fixed-response rule serving the JWKS at `/api/auth/keys`.
- **ECS:** the cluster, three task definitions (replication / api / compact), the replication and api
  services, autoscaling policies, and the scheduled compaction rule.
- **Secrets:** the config secrets, the cw-agent SSM parameter, and the generated JWT key.
- **IAM:** execution / task / events roles, with an optional permissions boundary.

`terraform apply` does not create the PowerSync database roles, publication, or storage database. A
one-time script does that (see [Database bootstrap](#database-bootstrap)). After apply, the api service
sits behind the ALB and the replicator connects once you run the bootstrap and seed the source
database (see [`../example-client`](../example-client)).

This runs billable infrastructure (RDS, ALB, NAT gateway, Fargate tasks). Destroy it when you are done.

## How it works

### Database (RDS Postgres)
One RDS instance holds two databases: `app` (your source data, including the demo `lists` table) and
`powersync` (PowerSync's bucket storage). Postgres 14+ supports co-locating the source and storage on
one instance; it raises CPU under load, so split onto a second instance for production. The replicator
consumes Postgres logical replication from the `powersync` publication.

Two least-privilege roles keep the connections scoped (the bootstrap in `example-client` creates them):

| Role | Scope | Used by |
|---|---|---|
| `powersync_source` | `SELECT` on the source db + `rds_replication` | the source/replication connection (read-only) |
| `powersync_storage` | owner of the `powersync` storage db | the bucket-storage connection (replication + compact + api) |

The RDS master user handles the one-time bootstrap and the seed scripts.

### ECS processes
| Service | Command | Role |
|---|---|---|
| `replication` | `start -r sync` | reads the source, writes bucket data. Single active instance (`desired_count = 1`). |
| `api` | `start -r api` | client-facing sync API behind the ALB. Autoscales 2 to 8 on CPU and concurrent connections. |
| `compact` | `compact` | scheduled bucket compaction (daily, 02:00 UTC) via EventBridge. |

Tasks run the public `journeyapps/powersync-service` image, pulled over the NAT gateway.

### Client auth
Terraform generates the RS256 signing key in `auth.tf`: the private key goes to Secrets Manager, and
the public half becomes the JWKS the ALB serves at `/api/auth/keys` (PowerSync's `jwks_uri`).
PowerSync validates tokens; the companion toolkit mints them locally, so this example deploys no auth
backend. Accepted audiences: `powersync-dev`, `authenticated`.

## Observability (optional)

Two flags in `locals.tf` gate the monitoring stack. Leave them off and none of it is created:

```hcl
enable_observability = true   # AMP metrics, Grafana dashboards, alerts
enable_opensearch    = true   # + OpenSearch full-text log search (the main always-on cost)
```

You get Amazon Managed Prometheus (metrics via an ADOT sidecar), Amazon Managed Grafana (dashboards),
an optional OpenSearch log pipeline, and CloudWatch + AMP alerts fanned through SNS to a forwarder
Lambda (durable log, optional Slack/webhook). OpenSearch carries the only meaningful always-on cost;
set `enable_opensearch = false` to keep metrics and dashboards at near-zero extra cost.

## Prerequisites

1. **AWS credentials** that resolve to `account_id` (a guard aborts otherwise).
2. **S3 state bucket** set in `versions.tf` (bootstrap it out of band). Terraform 1.10+ for native S3
   locking.
3. **Route 53 hosted zone** for `base_domain`. Terraform requests the ACM cert, writes the validation
   records, and creates the `<deployment_name>.<base_domain>` alias.
4. **Node 20+** (the bootstrap and example client run from `example-client`), and network reachability
   to RDS (set `admin_cidr` to your workstation IP).

## Setup

```bash
cp ../.env.example ../.env   # fill in, then load it (direnv, or `set -a; source ../.env; set +a`)
```

Set `account_id`, `base_domain`, and `route53_zone_id`. Set `admin_cidr` to your IP and pick a
`deployment_name`.

## Apply

The `bucket` lives in `versions.tf`; pass the per-deployment state `key` at init (see the backend note
in `versions.tf`):

```bash
terraform init -backend-config="key=$TF_VAR_deployment_name/infra/terraform.tfstate"
terraform fmt -check && terraform validate
terraform apply        # network, RDS, ECS, ALB
```

## Database bootstrap

After apply, run the one-time bootstrap to create PowerSync's Postgres roles, publication, and storage
database:

```bash
cd ../example-client && npm install
npm run bootstrap
```

It runs from the companion toolkit (Node and the `pg` driver), reads the endpoint and the generated
role passwords from `terraform output`, and temporarily allowlists your IP on the RDS security group.
It is idempotent. The ECS services retry their database connection until it completes, then go healthy
and begin replication.

## Verify

```bash
terraform output                                              # review outputs
curl https://$(terraform output -raw domain_url | sed 's#https://##')/probes/liveness   # 200 when healthy
curl "$(terraform output -raw domain_url)/api/auth/keys"      # the served JWKS ({"keys":[...]})
aws logs tail /ecs/$TF_VAR_deployment_name-replication --follow   # replicator connected + idle
```

Then seed and run a client per [`../example-client/README.md`](../example-client/README.md).

## Running multiple deployments

Every named resource carries the `deployment_name` prefix, and RDS has no cross-deployment
constraints, so a second copy in the same account and region needs a second `deployment_name` and its
own state key:

```bash
TF_VAR_deployment_name=staging terraform init -reconfigure \
  -backend-config="key=staging/infra/terraform.tfstate"
TF_VAR_deployment_name=staging terraform apply
```

Keep `deployment_name` short (under about 20 chars) so derived names stay within AWS limits
(ALB/target-group 32, OpenSearch domain 28).

## Destroy

```bash
terraform destroy
```

The RDS instance skips its final snapshot and secrets use a 0-day recovery window, so teardown is
quick. Both are demo defaults; harden them for production.

## Using MongoDB Atlas instead of RDS

`modules/atlas-cluster` is a worked example of using MongoDB Atlas over AWS PrivateLink as the data
layer. The commented block in `main.tf` shows how to wire it. One caveat: Atlas permits a single
PrivateLink service per region and project, so on Atlas the `deployment_name` prefix does not isolate
multiple deployments the way RDS does.

## AI disclaimer

This repo contains code generated with Claude, then reviewed and edited by hand.
