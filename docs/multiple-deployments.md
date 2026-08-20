# Running multiple deployments

One copy of this Terraform can run several times in the same AWS account and region. Each copy is a
separate deployment with its own network, database, ECS services, ALB, and subdomain. This document
is for a platform team that operates more than one deployment (for example `demo` and `staging`) and
needs them to coexist without interfering. For the single-deployment workflow, see
[`../infra/README.md`](../infra/README.md).

## `deployment_name` drives everything

`var.deployment_name` is the one input that makes deployments distinct. It is set as
`name_prefix` in [`../infra/locals.tf`](../infra/locals.tf) and prefixes every named resource
(`<name>-vpc`, `<name>-cluster`, `<name>-alb`, `<name>/config`, and so on).

It is validated in [`../infra/variables.tf`](../infra/variables.tf):

```
condition = can(regex("^[a-z][a-z0-9-]{1,23}$", var.deployment_name))
```

The name must be 2 to 24 characters, start with a lowercase letter, and contain only lowercase
letters, digits, and hyphens. That is a DNS-label-safe pattern, which matters because the name also
becomes a subdomain. The default is `powersync`.

## The three things that keep deployments separate

All three are driven by `deployment_name`.

### 1. Distinct resource names

Because `name_prefix = var.deployment_name`, every resource carries the prefix. Two deployments with
different names produce two disjoint sets of named resources in the same account and region, with no
collisions.

### 2. Distinct S3 state key

The backend is configured in [`../infra/versions.tf`](../infra/versions.tf):

```
backend "s3" {
  bucket       = "powersync-hosting-example-tf-state" # replace with your own bucket
  # key        = "demo/infra/terraform.tfstate"       # set per deployment
  region       = "us-east-1"
  encrypt      = true
  use_lockfile = true
}
```

The bucket is shared by all deployments. Each deployment gets its own state file through a distinct
`key`. The convention is `<deployment_name>/infra/terraform.tfstate`. The `key` is a partial backend
configuration: it is left out of the committed block and passed at `terraform init`.

### 3. Distinct subdomain

`domain = "${var.deployment_name}.${var.base_domain}"` in
[`../infra/locals.tf`](../infra/locals.tf). Deriving the host from the deployment name puts each
deployment on its own subdomain automatically inside one shared Route 53 zone (identified by
`var.route53_zone_id`). A PowerSync API needs its own dedicated subdomain, so this mapping is not
optional. The ALB, the ACM certificate, and the Route 53 alias all follow from `domain`.

## Commands

Initialize the first deployment, passing the per-deployment state key:

```bash
terraform init -backend-config="key=demo/infra/terraform.tfstate"
terraform apply
```

To stand up a second deployment from the same working directory, change both `deployment_name` and
the state `key`, and re-initialize with `-reconfigure` so Terraform switches to the new state file:

```bash
TF_VAR_deployment_name=staging terraform init -reconfigure \
  -backend-config="key=staging/infra/terraform.tfstate"
TF_VAR_deployment_name=staging terraform apply
```

The `deployment_name` and the first segment of the state `key` should match. Nothing enforces this,
but keeping them aligned means one name identifies both the resources and their state file.

## Why the state key is not hardcoded

If the `key` were committed as a fixed value, everyone running `terraform init` would bind to the
same state file. Two people applying different `deployment_name` values would then write to one
state and clobber each other's tracked resources. Leaving `key` out of the committed backend block
and passing it at init forces each deployment onto its own state file, so concurrent operators do
not share (or corrupt) state.

## Naming length limits

`deployment_name` allows up to 24 characters, but some AWS resource names derived from the prefix
are shorter. Keep the name short (roughly under 20 characters) so every derived name stays within
its limit:

| Resource | Name limit |
|---|---|
| ALB and target group | 32 characters |
| OpenSearch domain (when observability is enabled) | 28 characters |

The prefix plus a suffix such as `-alb` or `-tg` has to fit inside these limits.

## RDS versus MongoDB Atlas

With **Amazon RDS for PostgreSQL** (the default in this repo), there is no cross-deployment
constraint. RDS instances are independent, so any number of deployments coexist in the same account
and region purely by carrying distinct `deployment_name` prefixes and distinct state keys.

With **MongoDB Atlas** (the optional worked example in `infra/modules/atlas-cluster`, commented out
in `infra/main.tf`), the story differs. Atlas permits a single PrivateLink service per region and
project. The `deployment_name` prefix does not isolate the PrivateLink layer the way it isolates RDS
resources. Atlas-backed deployments that share a region and project would collide on that single
PrivateLink service, so give each Atlas-backed deployment its own Atlas project or its own region.
