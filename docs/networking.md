# Networking and the public surface

This document describes the network topology this Terraform builds, the security groups that gate
traffic, and where the public boundary sits. It is written for a security or network reviewer. Every
claim maps to a resource in [`../infra/modules/network/main.tf`](../infra/modules/network/main.tf),
[`../infra/modules/alb/main.tf`](../infra/modules/alb/main.tf), or the database security group in
[`../infra/modules/rds/main.tf`](../infra/modules/rds/main.tf). For the module layout and the apply
workflow, see [`../infra/README.md`](../infra/README.md).

## VPC layout

The deployment provisions one dedicated VPC with DNS support and DNS hostnames enabled. The CIDR and
subnet ranges are passed from the network module call in `infra/main.tf`:

| Component | CIDR | Subnets |
|---|---|---|
| VPC | `10.20.0.0/16` | |
| Public subnets | `10.20.0.0/20`, `10.20.16.0/20` | one `/20` per availability zone |
| Private subnets | `10.20.96.0/20`, `10.20.112.0/20` | one `/20` per availability zone |

The two availability zones come from the first two entries of `aws_availability_zones` in the region.

**Public subnets** carry the internet-facing ALB, the NAT gateway, and (in the demo) the RDS
instance. They have `map_public_ip_on_launch = true` and a default route to the internet gateway.

**Private subnets** carry the ECS Fargate tasks. They have no route to the internet gateway. Their
default route points at the NAT gateway, so tasks reach outbound destinations but nothing on the
internet can open a connection to them.

An internet gateway attaches to the VPC. A single NAT gateway lives in the first public subnet, with
one Elastic IP. This single NAT gateway is the demo default; it is a single point of failure and a
single-AZ egress path. For production high availability, run one NAT gateway per AZ and give each
private subnet a route table pointing at the NAT gateway in its own zone.

Two route tables carry the traffic:

- The public route table sends `0.0.0.0/0` to the internet gateway and associates with both public
  subnets.
- The private route table sends `0.0.0.0/0` to the NAT gateway and associates with both private
  subnets.

## Security groups

Three security groups form the perimeter. They reference each other by ID rather than by CIDR, so
the app-tier and database-tier rules stay tied to the actual workloads.

### ALB security group

Ingress: TCP 443 from `0.0.0.0/0`. This is the one deliberately internet-facing rule. Egress: all
outbound.

### ECS task security group

Ingress: TCP 8080 from the ALB security group only. Nothing else can reach the tasks, and the rule
is scoped to the ALB's security group rather than a CIDR.

Port 9090 (Prometheus telemetry) is intentionally not opened. The metrics endpoint is scraped over
localhost inside the task by the sidecar collector; it never appears on a security group or on the
ALB. See `prometheus_port` in [`../infra/locals.tf`](../infra/locals.tf).

Egress: all outbound. Tasks need this to pull the public container image, reach AWS APIs, and fetch
the JWKS URL, all over the NAT gateway. The database connection stays in-VPC (see below).

### RDS security group

Defined in [`../infra/modules/rds/main.tf`](../infra/modules/rds/main.tf). Ingress on TCP 5432 comes
from two sources:

1. The ECS task security group (referenced by ID), so the tasks reach Postgres in-VPC.
2. `var.admin_cidr`, a list of CIDR blocks, added only when the list is non-empty via a `dynamic`
   ingress block. This is meant for a workstation IP (for example `["203.0.113.4/32"]`) that runs
   the database bootstrap and seed scripts. Leave `admin_cidr` empty to allow in-VPC access only.

Egress: all outbound.

## Egress paths

- **ECS tasks to the internet:** through the NAT gateway. This covers the public container image
  pull, calls to AWS APIs, and the JWKS fetch. No task holds a public IP.
- **ECS tasks to the database:** in-VPC on 5432. The RDS security group admits the ECS security
  group directly; this traffic does not traverse the NAT gateway.
- **RDS:** reached in-VPC by the tasks (and, in the demo, from `admin_cidr`). Its egress is open but
  the database initiates no outbound connections in normal operation.

## ALB specifics

From [`../infra/modules/alb/main.tf`](../infra/modules/alb/main.tf):

- **TLS termination:** an internet-facing (`internal = false`) application load balancer with an
  HTTPS listener on 443. The certificate is an ACM certificate for `<deployment_name>.<base_domain>`,
  validated by DNS through Route 53 records that Terraform creates and destroys. The listener uses
  the `ELBSecurityPolicy-TLS13-1-2-2021-06` SSL policy. There is no HTTP (port 80) listener.
- **Route 53 alias:** an A record aliases `<deployment_name>.<base_domain>` to the ALB, with
  `evaluate_target_health = true`.
- **Target group:** forwards to the ECS tasks on 8080 over HTTP with `target_type = "ip"`. The
  health check probes `/probes/liveness` (200 expected). New connections use the
  `least_outstanding_requests` algorithm so long-lived streams spread to the least-loaded target.
- **`idle_timeout = 3600`:** raised well above the 60-second default because sync connections are
  long-lived. A too-low idle timeout would drop active syncs.
- **`deregistration_delay = 300`:** on scale-in, a target draining out of the pool has 300 seconds
  for active syncs to finish before the connection is forced closed.
- **JWKS fixed-response rule:** listener rule priority 10 matches path `/api/auth/keys` and returns
  the public JWK set as a fixed `application/json` 200 response, straight off the ALB with no task
  involved. The body is the RS256 public key set generated in Terraform (see `auth.tf` and
  `jwks_json` in [`../infra/locals.tf`](../infra/locals.tf)). PowerSync fetches this URL as its
  `jwks_uri`. The ALB caps fixed-response bodies at 1024 bytes, which fits one key; rotating the key
  means re-running `terraform apply`.

## RDS access posture

In the demo, the RDS instance is created with `publicly_accessible = true` and placed in the public
subnets. This lets you seed the database and run the example client from a laptop without a bastion
or a tunnel. The public endpoint is not open access: the RDS security group is the real gate, and it
admits only the ECS tasks and `var.admin_cidr`.

To harden this for production:

- Set `publicly_accessible = false` on the RDS instance in
  [`../infra/modules/rds/main.tf`](../infra/modules/rds/main.tf).
- Place the instance in the private subnets (pass the private subnet IDs to the module's
  `subnet_ids` at the call site in `infra/main.tf` instead of the public ones).
- Reach the database for administrative tasks through a bastion host or an SSM tunnel rather than a
  workstation CIDR, and leave `admin_cidr` empty.

## Public-surface summary

The only intentionally internet-facing endpoint is the ALB on 443. Everything else is private or
gated:

| Surface | Reachable from | Notes |
|---|---|---|
| ALB (443) | Internet | The single public entry point (TLS, sync API, and the JWKS response). |
| ECS tasks (8080) | ALB security group only | In private subnets, no public IP. |
| Prometheus (9090) | localhost inside the task | Never on a security group or the ALB. |
| RDS (5432) | ECS security group and `var.admin_cidr` | Demo places it in public subnets; gate it and/or make it private for production. |
| OpenSearch endpoint | Internet, when the optional log pipeline is enabled | Only present when `enable_opensearch = true`. |

When the optional observability stack turns on OpenSearch (`enable_opensearch = true` in
[`../infra/locals.tf`](../infra/locals.tf)), its domain endpoint is the one additional public
surface. With OpenSearch off, the ALB is the sole public endpoint.
