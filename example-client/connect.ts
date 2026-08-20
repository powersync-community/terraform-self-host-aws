// Headless PowerSync client. Connects to the deployed endpoint as example-user, waits for the first
// sync to finish, prints the synced `lists` rows, then exits. Use it to verify the full sync path
// (Postgres -> replicator -> bucket storage -> sync API -> client) without opening the browser.
//
//   npm run connect
import { PowerSyncDatabase, Schema, Table, column } from "@powersync/node";
import { mintToken } from "./lib/mint.ts";

const schema = new Schema({
  lists: new Table({ owner_id: column.text, name: column.text, created_at: column.text }),
});

const { endpoint, token } = await mintToken();
console.log(`connecting to ${endpoint} as example-user ...`);

const db = new PowerSyncDatabase({ schema, database: { dbFilename: "connect-cli.db" } });
await db.connect({
  fetchCredentials: async () => ({ endpoint, token }),
  uploadData: async () => {}, // read-only; real apps upload writes to their own backend API
});

// Wait for the first sync, but do not hang forever if the client cannot authorize or reach the endpoint.
const controller = new AbortController();
const timeout = setTimeout(() => controller.abort(), 30_000);
try {
  await db.waitForFirstSync({ signal: controller.signal });
} catch {
  console.error("first sync did not complete within 30s. Check the token is accepted and the endpoint is reachable.");
  await db.disconnect();
  await db.close();
  process.exit(1);
}
clearTimeout(timeout);

const rows = await db.getAll<{ id: string; name: string; owner_id: string }>(
  "SELECT id, owner_id, name, created_at FROM lists ORDER BY name",
);
console.log(`synced ${rows.length} list(s) for example-user:`);
for (const r of rows) console.log(`  - ${r.name}`);

await db.disconnect();
await db.close();
process.exit(0);
