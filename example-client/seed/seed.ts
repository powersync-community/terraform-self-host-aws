// Seed the demo `lists` table in the source database. Idempotent: creates the table if needed,
// clears it, then inserts a small generated dataset. Reads connection details from terraform
// outputs; access via the temporary RDS security-group allowlist.
//
// Rows are owned by two users so you can see the sync rule scope things: the example client mints
// a token for `example-user` (see auth/mint-token.ts), so only that user's rows sync to it.
//
//   npm run seed
import { tfOutput } from "../lib/tf-outputs.ts";
import { withTempAccess } from "./lib/rds-allowlist.ts";
import { clientConfig, connectWithRetry, SOURCE_TABLE } from "./lib/pg.ts";

const DEMO_USER = "example-user"; // must match the JWT `sub` minted in auth/mint-token.ts
const OTHER_USER = "someone-else"; // rows that must not sync to the demo user

// The source role is SELECT-only, so seeding connects as the RDS master user (admin).
function adminConfig() {
  return clientConfig({
    host: tfOutput("db_host"),
    port: Number(tfOutput("db_port")),
    user: tfOutput("db_master_username"),
    password: tfOutput("db_master_password"),
    database: tfOutput("db_source_database"),
  });
}

const rows = [
  ...Array.from({ length: 8 }, (_, i) => ({ owner: DEMO_USER, name: `Groceries ${i + 1}` })),
  ...Array.from({ length: 4 }, (_, i) => ({ owner: OTHER_USER, name: `Not yours ${i + 1}` })),
];

await withTempAccess(async () => {
  const client = await connectWithRetry(adminConfig());
  try {
    await client.query(`
      CREATE TABLE IF NOT EXISTS ${SOURCE_TABLE} (
        id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        owner_id   text NOT NULL,
        name       text NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now()
      )
    `);
    // Grant the source (replication) role read access to this table, needed if the table was
    // created after the initial bootstrap grants. Idempotent.
    await client.query(`GRANT SELECT ON ${SOURCE_TABLE} TO ${tfOutput("db_source_username")}`);

    await client.query(`TRUNCATE ${SOURCE_TABLE}`);
    for (const r of rows) {
      await client.query(`INSERT INTO ${SOURCE_TABLE} (owner_id, name) VALUES ($1, $2)`, [r.owner, r.name]);
    }

    const { rows: counts } = await client.query<{ owner_id: string; n: string }>(
      `SELECT owner_id, count(*)::text AS n FROM ${SOURCE_TABLE} GROUP BY owner_id ORDER BY owner_id`
    );
    console.log(`✅ seeded ${rows.length} rows into ${tfOutput("db_source_database")}.${SOURCE_TABLE}:`);
    for (const c of counts) console.log(`   ${c.owner_id}: ${c.n}`);
    console.log(`   the replicator picks up the change within a few seconds`);
    console.log(`   (the example client syncs only ${DEMO_USER}'s rows)`);
  } finally {
    await client.end();
  }
});
