import { Client, type ClientConfig } from "pg";

// The source application database, and the demo table PowerSync syncs.
export const SOURCE_TABLE = "lists";

// Build a pg connection config from Terraform outputs. TLS is enabled but not CA-verified — this
// is a local admin script talking to the (demo) publicly-accessible RDS instance; the sync path
// itself never touches the DB directly.
export function clientConfig(opts: {
  host: string;
  port: number;
  user: string;
  password: string;
  database: string;
}): ClientConfig {
  return {
    ...opts,
    ssl: { rejectUnauthorized: false },
    connectionTimeoutMillis: 8000,
  };
}

// A freshly-authorized security-group rule can take a moment to take effect, so retry the first
// connection a few times before giving up.
export async function connectWithRetry(config: ClientConfig, attempts = 8, delayMs = 4000): Promise<Client> {
  let lastErr: unknown;
  for (let i = 1; i <= attempts; i++) {
    const client = new Client(config);
    try {
      await client.connect();
      await client.query("SELECT 1");
      return client;
    } catch (e) {
      lastErr = e;
      await client.end().catch(() => {});
      console.log(`  connect attempt ${i}/${attempts} failed (security-group rule may still be propagating)…`);
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
  throw lastErr;
}
