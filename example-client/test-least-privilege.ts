// Proves the source (replication) role is correctly least-privileged:
//   1. It can READ the source data (SELECT on the `lists` table)  — replication needs this.
//   2. It CANNOT write the source data (INSERT denied)            — replication only reads.
//   3. It CANNOT reach the bucket-storage database at all         — that's the storage role's job.
// Connects AS the source role (creds from terraform outputs) and asserts each case.
//
//   npm run test:least-privilege
import { tfOutput } from "./lib/tf-outputs.ts";
import { withTempAccess } from "./seed/lib/rds-allowlist.ts";
import { clientConfig, connectWithRetry, SOURCE_TABLE } from "./seed/lib/pg.ts";

function sourceConfig(database: string) {
  return clientConfig({
    host: tfOutput("db_host"),
    port: Number(tfOutput("db_port")),
    user: tfOutput("db_source_username"),
    password: tfOutput("db_source_password"),
    database,
  });
}

function isDenied(e: unknown): boolean {
  // 42501 = insufficient_privilege; connection refusal to the storage db also surfaces as an error.
  const err = e as { code?: string; message?: string };
  return err?.code === "42501" || /permission denied|not authorized|no pg_hba|database .* does not|denied/i.test(err?.message ?? "");
}

const results: { name: string; pass: boolean; detail: string }[] = [];
function record(name: string, pass: boolean, detail: string) {
  results.push({ name, pass, detail });
  console.log(`${pass ? "✅ PASS" : "❌ FAIL"}  ${name} — ${detail}`);
}

await withTempAccess(async () => {
  // 1 + 2: against the SOURCE database.
  const src = await connectWithRetry(sourceConfig(tfOutput("db_source_database")));
  try {
    try {
      await src.query(`SELECT * FROM ${SOURCE_TABLE} LIMIT 1`);
      record("read source lists", true, "SELECT allowed (replication reads the source)");
    } catch (e) {
      record("read source lists", false, `unexpected read denial: ${(e as Error).message}`);
    }

    try {
      await src.query(`INSERT INTO ${SOURCE_TABLE} (owner_id, name) VALUES ('_probe', '_probe')`);
      await src.query(`DELETE FROM ${SOURCE_TABLE} WHERE owner_id = '_probe'`).catch(() => {});
      record("write source lists (must be denied)", false, "INSERT SUCCEEDED — source role is over-privileged!");
    } catch (e) {
      record("write source lists (must be denied)", isDenied(e), isDenied(e) ? "correctly denied (SELECT-only)" : `denied but unexpected: ${(e as Error).message}`);
    }
  } finally {
    await src.end();
  }

  // 3: the source role must NOT be able to reach the bucket-storage database.
  try {
    const stg = await connectWithRetry(sourceConfig(tfOutput("db_storage_database")), 2, 2000);
    await stg.end();
    record("reach storage db (must be denied)", false, "CONNECT SUCCEEDED — source role can reach bucket storage!");
  } catch (e) {
    record("reach storage db (must be denied)", isDenied(e), isDenied(e) ? "correctly denied (no access to storage db)" : `denied but unexpected: ${(e as Error).message}`);
  }
});

const failed = results.filter((r) => !r.pass);
console.log(`\n${failed.length === 0 ? "🎉 all checks passed — least-privilege scoping verified" : `⚠️ ${failed.length} check(s) failed`}`);
process.exit(failed.length === 0 ? 0 : 1);
