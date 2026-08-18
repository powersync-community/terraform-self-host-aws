terraform {
  # 1.10+ for the S3-native state locking (use_lockfile) below.
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    # Community provider (v0.x, single maintainer) — computes a JWKS from a PEM key so the
    # ALB-served public key set is generated in-Terraform instead of a committed static file.
    jwks = {
      source  = "iwarapter/jwks"
      version = "~> 0.1"
    }
    # Manages AMG datasources + dashboards as code. Only used when enable_observability is true.
    grafana = {
      source  = "grafana/grafana"
      version = "~> 3.0"
    }
    # Maps the log-indexer Lambda's IAM role to an OpenSearch write role. Only used when
    # enable_opensearch is true.
    opensearch = {
      source  = "opensearch-project/opensearch"
      version = "~> 2.2"
    }
    # NOTE: the optional MongoDB Atlas example (modules/atlas-cluster, commented out in main.tf)
    # additionally needs the mongodb/mongodbatlas provider. Uncomment it here if you enable that path:
    #   mongodbatlas = {
    #     source  = "mongodb/mongodbatlas"
    #     version = "~> 2.0"
    #   }
  }

  # State backend: S3 with S3-native locking. The bucket is shared by all deployments; each gets its
  # own state file via a distinct `key`. Set `key` to <deployment_name>/infra/terraform.tfstate so
  # two deployments never share state. Either uncomment and edit the line below, then:
  #   terraform init
  # or leave it commented and pass it at init:
  #   terraform init -backend-config="key=demo/infra/terraform.tfstate"
  backend "s3" {
    bucket = "powersync-hosting-example-tf-state" # replace with your S3 state bucket (globally unique)
    # key        = "demo/infra/terraform.tfstate" # uncomment and set to <deployment_name>/infra/terraform.tfstate
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
