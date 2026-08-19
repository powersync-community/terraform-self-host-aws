// Drop the demo `lists` table in the source database. Access via the temporary RDS
// security-group allowlist. Connects as the RDS master user (the source role is read-only).
//
//   npm run clear
import { tfOutput } from "../lib/tf-outputs.ts";
import { withTempAccess } from "./lib/rds-allowlist.ts";
import { clientConfig, connectWithRetry, SOURCE_TABLE } from "./lib/pg.ts";

function adminConfig() {
  return clientConfig({
    host: tfOutput("db_host"),
    port: Number(tfOutput("db_port")),
    user: tfOutput("db_master_username"),
    password: tfOutput("db_master_password"),
    database: tfOutput("db_source_database"),
  });
}

await withTempAccess(async () => {
  const client = await connectWithRetry(adminConfig());
  try {
    const { rowCount } = await client.query(`SELECT 1 FROM information_schema.tables WHERE table_name = '${SOURCE_TABLE}'`);
    await client.query(`DROP TABLE IF EXISTS ${SOURCE_TABLE}`);
    console.log(rowCount ? `✅ dropped ${SOURCE_TABLE}` : `ℹ️  ${SOURCE_TABLE} did not exist, nothing to drop`);
  } finally {
    await client.end();
  }
});
