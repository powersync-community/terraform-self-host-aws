// One-time database bootstrap: create the two least-privilege PowerSync roles, the `powersync`
// publication, the bucket-storage database, and the source-read grants. Idempotent and safe to re-run.
//
// Run this once after `terraform apply` and before seeding / starting to sync. It reads everything
// from terraform outputs (endpoint, master creds, and the Terraform-generated role passwords) and
// connects as the RDS master user via the pg driver. Access uses the same temporary RDS
// security-group allowlist as the seed scripts.
//
//   npm run bootstrap
import { tfOutput } from "./lib/tf-outputs.ts";
import { withTempAccess } from "./seed/lib/rds-allowlist.ts";
import { clientConfig, connectWithRetry } from "./seed/lib/pg.ts";

const sourceDb = tfOutput("db_source_database");
const storageDb = tfOutput("db_storage_database");
const sourceRole = tfOutput("db_source_username");
const storageRole = tfOutput("db_storage_username");
const sourcePw = tfOutput("db_source_password"); // alphanumeric (generated special=false) -> safe to inline
const storagePw = tfOutput("db_storage_password");

function masterConfig(database: string) {
  return clientConfig({
    host: tfOutput("db_host"),
    port: Number(tfOutput("db_port")),
    user: tfOutput("db_master_username"),
    password: tfOutput("db_master_password"),
    database,
  });
}

async function exists(c: import("pg").Client, sql: string, params: unknown[]): Promise<boolean> {
  const { rowCount } = await c.query(sql, params);
  return (rowCount ?? 0) > 0;
}

await withTempAccess(async () => {
  const c = await connectWithRetry(masterConfig(sourceDb));
  try {
    // 1. Roles (idempotent). Passwords are alphanumeric, so inlining them is safe.
    await c.query(`DO $$ BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${sourceRole}') THEN
        CREATE ROLE ${sourceRole} LOGIN PASSWORD '${sourcePw}';
      ELSE
        ALTER ROLE ${sourceRole} WITH LOGIN PASSWORD '${sourcePw}';
      END IF;
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${storageRole}') THEN
        CREATE ROLE ${storageRole} LOGIN PASSWORD '${storagePw}';
      ELSE
        ALTER ROLE ${storageRole} WITH LOGIN PASSWORD '${storagePw}';
      END IF;
    END $$;`);
    console.log(`✅ roles ${sourceRole} / ${storageRole} ready`);

    // 2. Logical replication privilege + source-read grants (current db = source).
    await c.query(`GRANT rds_replication TO ${sourceRole}`);
    await c.query(`GRANT CONNECT ON DATABASE ${sourceDb} TO ${sourceRole}`);
    await c.query(`GRANT USAGE ON SCHEMA public TO ${sourceRole}`);
    await c.query(`GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${sourceRole}`);
    await c.query(`ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ${sourceRole}`);
    console.log(`✅ source-read grants applied to ${sourceRole}`);

    // 3. Publication PowerSync replicates from (FOR ALL TABLES also covers tables created later).
    if (!(await exists(c, `SELECT 1 FROM pg_publication WHERE pubname = 'powersync'`, []))) {
      await c.query(`CREATE PUBLICATION powersync FOR ALL TABLES`);
      console.log(`✅ created publication "powersync"`);
    } else {
      console.log(`ℹ️  publication "powersync" already exists`);
    }

    // 4. Bucket-storage database, owned by the storage role (CREATE DATABASE can't run in a txn;
    //    node-postgres autocommits a lone statement, so this is fine).
    if (!(await exists(c, `SELECT 1 FROM pg_database WHERE datname = $1`, [storageDb]))) {
      await c.query(`CREATE DATABASE ${storageDb} OWNER ${storageRole}`);
      console.log(`✅ created storage database "${storageDb}" (owner ${storageRole})`);
    } else {
      console.log(`ℹ️  storage database "${storageDb}" already exists`);
    }

    console.log(`\n🎉 bootstrap complete. Next: npm run seed`);
  } finally {
    await c.end();
  }
});
