###############################################################################
# Postgres bootstrap.
#
# Terraform (modules/rds) creates the instance and the source database (`app`). The objects
# PowerSync needs on top of that — its two least-privilege roles, the bucket-storage database,
# the `powersync` publication, and the source-read grants — are created here by running an
# idempotent SQL script through psql against the instance.
#
# Why psql (and not a Postgres Terraform provider): it keeps the bootstrap transparent and
# provider-free, and runs from wherever you run Terraform. Requirements:
#   - `psql` on PATH.
#   - Network reachability to the instance (it is publicly accessible in this demo; the RDS
#     security group must allow your IP — set var.admin_cidr to your workstation CIDR).
# Passwords are generated with special=false (alphanumeric), so they are safe to inline in SQL.
###############################################################################

resource "random_password" "pg_source" {
  length  = 32
  special = false
}

resource "random_password" "pg_storage" {
  length  = 32
  special = false
}

resource "terraform_data" "db_bootstrap" {
  # Re-run when the instance changes or when the credentials/SQL change.
  triggers_replace = {
    instance = module.rds.instance_id
    creds    = sha256("${random_password.pg_source.result}:${random_password.pg_storage.result}")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      PGPASSWORD = module.rds.master_password
    }
    command = <<-EOT
      set -euo pipefail
      psql "sslmode=require host=${module.rds.address} port=${module.rds.port} user=${module.rds.master_username} dbname=${local.source_db}" -v ON_ERROR_STOP=1 <<'SQL'

      -- Least-privilege roles (idempotent). --------------------------------------------------
      DO $$ BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${local.source_role}') THEN
          CREATE ROLE ${local.source_role} LOGIN PASSWORD '${random_password.pg_source.result}';
        ELSE
          ALTER ROLE ${local.source_role} WITH LOGIN PASSWORD '${random_password.pg_source.result}';
        END IF;
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${local.storage_role}') THEN
          CREATE ROLE ${local.storage_role} LOGIN PASSWORD '${random_password.pg_storage.result}';
        ELSE
          ALTER ROLE ${local.storage_role} WITH LOGIN PASSWORD '${random_password.pg_storage.result}';
        END IF;
      END $$;

      -- Logical replication privilege for the source role (RDS grants it via rds_replication).
      GRANT rds_replication TO ${local.source_role};

      -- Source read grants for the replicator (current database = ${local.source_db}).
      GRANT CONNECT ON DATABASE ${local.source_db} TO ${local.source_role};
      GRANT USAGE ON SCHEMA public TO ${local.source_role};
      GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${local.source_role};
      ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ${local.source_role};

      -- Publication PowerSync replicates from. FOR ALL TABLES also covers tables created later
      -- (e.g. the demo `lists` table seeded by example-client). Created once.
      SELECT 'CREATE PUBLICATION powersync FOR ALL TABLES'
      WHERE NOT EXISTS (SELECT FROM pg_publication WHERE pubname = 'powersync')\gexec

      -- Bucket-storage database, owned by the storage role (full privileges within it). Created once.
      SELECT 'CREATE DATABASE ${local.storage_db} OWNER ${local.storage_role}'
      WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${local.storage_db}')\gexec
      SQL
    EOT
  }

  depends_on = [module.rds]
}
