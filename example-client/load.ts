// Load generator. Simulates many clients against the deployed endpoint so the dashboard panels and
// alerts have something to show:
//
//   - N virtual users (`load-user-0` ... `load-user-<N-1>`), each with its own token and its own
//     seeded `lists` rows, so every user gets its own bucket.
//   - Churn: each user opens a sync stream, holds it for a random time, disconnects, pauses, and
//     reconnects. This moves concurrent connections and powersync_sync_connections_total.
//   - Writer: inserts, updates and deletes `lists` rows in the source database at a fixed rate. This
//     moves replication, operations and data-synced metrics.
//   - Burst (optional): opens many extra streams at once, mid-run, to go past the per-task
//     max_concurrent_connections limit. The extra streams are rejected with 429, which shows up as
//     outcome="rejected" and fires PowerSyncSyncConnectionErrors.
//
// Clients speak the sync protocol directly over HTTP (no SQLite, no SDK), so a laptop can run
// hundreds of them. Rows created for load users are deleted at the end (unless --keep).
//
//   npm run load                                  # defaults: 50 users, 10 min, 2 writes/s
//   npm run load -- --users 200 --duration 30m
//   npm run load -- --burst 500                   # also exercise rejections
//   npm run load -- --writes 0 --rows 0           # connections only, no database access
//
// Run `npm run seed` once first, so the `lists` table exists.
import { parseArgs } from "node:util";
import type { Client } from "pg";
import { createMinter } from "./lib/mint.ts";
import { tfOutput } from "./lib/tf-outputs.ts";
import { withTempAccess } from "./seed/lib/rds-allowlist.ts";
import { clientConfig, connectWithRetry, SOURCE_TABLE } from "./seed/lib/pg.ts";

const USER_PREFIX = "load-user-";

// --- Options ---------------------------------------------------------------------------------

// `pnpm load -- --users 10` passes the `--` through (npm strips it), so drop a leading one.
const argv = process.argv.slice(2);
if (argv[0] === "--") argv.shift();

const { values: args } = parseArgs({
  args: argv,
  options: {
    users: { type: "string", default: "50" }, //        virtual users (one stream each at a time)
    duration: { type: "string", default: "10m" }, //    total run time; 0 = until Ctrl-C
    ramp: { type: "string", default: "30s" }, //        spread the first connections over this time
    "hold-min": { type: "string", default: "10s" }, //  shortest time a stream stays open
    "hold-max": { type: "string", default: "2m" }, //   longest time a stream stays open
    "pause-min": { type: "string", default: "1s" }, //  shortest pause before reconnecting
    "pause-max": { type: "string", default: "5s" }, //  longest pause before reconnecting
    rows: { type: "string", default: "5" }, //          rows seeded per user at start
    writes: { type: "string", default: "2" }, //        source-database writes per second
    burst: { type: "string", default: "0" }, //         extra streams opened at once, mid-run
    "burst-hold": { type: "string", default: "30s" }, //how long burst streams stay open
    keep: { type: "boolean", default: false }, //       keep load-user rows at the end
    help: { type: "boolean", short: "h", default: false },
  },
});

if (args.help) {
  console.log(
    "npm run load -- [--users 50] [--duration 10m] [--ramp 30s] [--hold-min 10s] [--hold-max 2m]\n" +
      "                [--pause-min 1s] [--pause-max 5s] [--rows 5] [--writes 2] [--burst 0]\n" +
      "                [--burst-hold 30s] [--keep]",
  );
  process.exit(0);
}

function duration(s: string): number {
  const m = /^(\d+(?:\.\d+)?)(ms|s|m|h)?$/.exec(s.trim());
  if (!m) throw new Error(`invalid duration "${s}" (use e.g. 500ms, 30s, 10m, 1h)`);
  const n = Number(m[1]);
  return n * { ms: 1, s: 1_000, m: 60_000, h: 3_600_000 }[(m[2] ?? "s") as "ms" | "s" | "m" | "h"];
}

const opts = {
  users: Number(args.users),
  durationMs: duration(args.duration!),
  rampMs: duration(args.ramp!),
  holdMin: duration(args["hold-min"]!),
  holdMax: duration(args["hold-max"]!),
  pauseMin: duration(args["pause-min"]!),
  pauseMax: duration(args["pause-max"]!),
  rows: Number(args.rows),
  writes: Number(args.writes),
  burst: Number(args.burst),
  burstHoldMs: duration(args["burst-hold"]!),
  keep: args.keep!,
};

// --- Shared state ----------------------------------------------------------------------------

const stats = {
  active: 0, //     streams open right now
  opened: 0, //     streams accepted (HTTP 200)
  closed: 0, //     streams we closed after their hold time
  ended: 0, //      streams the server closed
  rejected: 0, //   HTTP 429 (over max_concurrent_connections)
  errors: 0, //     any other failure
  checkpoints: 0, //checkpoint_complete lines received
  bytes: 0, //      sync data received
  writes: 0, //     source-database writes done
};
let lastError = "";
let stopping = false;
const open = new Set<AbortController>();

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const between = (min: number, max: number) => min + Math.random() * Math.max(0, max - min);
const pick = <T>(xs: T[]) => xs[Math.floor(Math.random() * xs.length)];

// Sleep that wakes early when the run stops.
async function wait(ms: number) {
  const end = Date.now() + ms;
  while (!stopping && Date.now() < end) await sleep(Math.min(250, end - Date.now()));
}

// --- Sync stream -----------------------------------------------------------------------------

// Open one sync stream and read it until holdMs passes or the server closes it.
async function stream(endpoint: string, token: string, clientId: string, holdMs: number) {
  const ac = new AbortController();
  open.add(ac);
  const timer = setTimeout(() => ac.abort(), holdMs);
  let accepted = false;
  try {
    const res = await fetch(`${endpoint}/sync/stream`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Token ${token}` },
      body: JSON.stringify({ raw_data: true, client_id: clientId, buckets: [] }),
      signal: ac.signal,
    });
    if (res.status === 429) {
      stats.rejected++;
      await res.body?.cancel();
      return;
    }
    if (!res.ok || !res.body) {
      stats.errors++;
      lastError = `HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`;
      return;
    }

    accepted = true;
    stats.opened++;
    stats.active++;
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buf = "";
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      stats.bytes += value.byteLength;
      buf += decoder.decode(value, { stream: true });
      const lines = buf.split("\n");
      buf = lines.pop()!;
      for (const line of lines) if (line.startsWith('{"checkpoint_complete"')) stats.checkpoints++;
    }
    stats.ended++; // the server closed the stream (e.g. token expiry, deploy)
  } catch (e) {
    if (ac.signal.aborted) {
      if (accepted) stats.closed++;
    } else {
      stats.errors++;
      lastError = (e as Error).message;
    }
  } finally {
    if (accepted) stats.active--;
    clearTimeout(timer);
    open.delete(ac);
  }
}

// One virtual user: connect, hold, disconnect, pause, repeat.
async function user(endpoint: string, token: string, i: number) {
  await wait((opts.rampMs / Math.max(1, opts.users)) * i);
  for (let n = 0; !stopping; n++) {
    await stream(endpoint, token, `load-${i}-${n}`, between(opts.holdMin, opts.holdMax));
    await wait(between(opts.pauseMin, opts.pauseMax));
  }
}

async function burst(endpoint: string, tokens: string[]) {
  console.log(`💥 burst: opening ${opts.burst} extra streams for ${fmt(opts.burstHoldMs)}`);
  await Promise.all(
    Array.from({ length: opts.burst }, (_, k) =>
      stream(endpoint, tokens[k % tokens.length], `load-burst-${k}`, opts.burstHoldMs),
    ),
  );
}

// --- Source database ---------------------------------------------------------------------------

function adminConfig() {
  return clientConfig({
    host: tfOutput("db_host"),
    port: Number(tfOutput("db_port")),
    user: tfOutput("db_master_username"),
    password: tfOutput("db_master_password"),
    database: tfOutput("db_source_database"),
  });
}

async function seedLoadUsers(db: Client) {
  const { rows } = await db.query<{ t: string | null }>(`SELECT to_regclass($1) AS t`, [SOURCE_TABLE]);
  if (!rows[0].t) throw new Error(`table "${SOURCE_TABLE}" does not exist. Run \`npm run seed\` first.`);
  await db.query(`DELETE FROM ${SOURCE_TABLE} WHERE owner_id LIKE $1`, [`${USER_PREFIX}%`]);
  if (opts.rows > 0) {
    await db.query(
      `INSERT INTO ${SOURCE_TABLE} (owner_id, name)
       SELECT $1 || u, 'Load list ' || r FROM generate_series(0, $2 - 1) u, generate_series(1, $3) r`,
      [USER_PREFIX, opts.users, opts.rows],
    );
  }
  console.log(`🌱 seeded ${opts.users * opts.rows} rows for ${opts.users} load users`);
}

// Random mix of writes, roughly balanced so the table does not grow without limit.
async function writer(db: Client) {
  const users = Array.from({ length: opts.users }, (_, i) => `${USER_PREFIX}${i}`);
  const interval = 1000 / opts.writes;
  while (!stopping) {
    const started = Date.now();
    const owner = pick(users);
    const roll = Math.random();
    try {
      if (roll < 0.5) {
        await db.query(
          `UPDATE ${SOURCE_TABLE} SET name = $2
           WHERE id = (SELECT id FROM ${SOURCE_TABLE} WHERE owner_id = $1 ORDER BY random() LIMIT 1)`,
          [owner, `Load list ${Math.floor(Math.random() * 1e6)}`],
        );
      } else if (roll < 0.8) {
        await db.query(`INSERT INTO ${SOURCE_TABLE} (owner_id, name) VALUES ($1, $2)`, [
          owner,
          `Load list ${Math.floor(Math.random() * 1e6)}`,
        ]);
      } else {
        await db.query(
          `DELETE FROM ${SOURCE_TABLE}
           WHERE id = (SELECT id FROM ${SOURCE_TABLE} WHERE owner_id = $1 ORDER BY random() LIMIT 1)`,
          [owner],
        );
      }
      stats.writes++;
    } catch (e) {
      stats.errors++;
      lastError = `write: ${(e as Error).message}`;
    }
    await wait(interval - (Date.now() - started));
  }
}

// --- Run ---------------------------------------------------------------------------------------

const fmt = (ms: number) => (ms >= 60_000 && ms % 60_000 === 0 ? `${ms / 60_000}m` : `${Math.round(ms / 1000)}s`);

function report(startedAt: number) {
  const t = Math.floor((Date.now() - startedAt) / 1000);
  const clock = `${String(Math.floor(t / 60)).padStart(2, "0")}:${String(t % 60).padStart(2, "0")}`;
  const mb = (stats.bytes / 1e6).toFixed(1);
  console.log(
    `[${clock}] active ${stats.active} | opened ${stats.opened} closed ${stats.closed} ended ${stats.ended} ` +
      `rejected ${stats.rejected} errors ${stats.errors} | checkpoints ${stats.checkpoints} | ${mb} MB | writes ${stats.writes}` +
      (lastError ? `\n         last error: ${lastError}` : ""),
  );
  lastError = "";
}

async function run(db: Client | null) {
  const { endpoint, mint } = await createMinter();
  const tokens = await Promise.all(Array.from({ length: opts.users }, (_, i) => mint(`${USER_PREFIX}${i}`)));
  if (db) await seedLoadUsers(db);

  const forever = opts.durationMs === 0;
  console.log(
    `🚀 ${opts.users} users against ${endpoint} for ${forever ? "until Ctrl-C" : fmt(opts.durationMs)}` +
      ` (hold ${fmt(opts.holdMin)}-${fmt(opts.holdMax)}, ${db ? `${opts.writes} writes/s` : "no writes"})`,
  );

  const startedAt = Date.now();
  const ticker = setInterval(() => report(startedAt), 10_000);
  const tasks: Promise<unknown>[] = Array.from({ length: opts.users }, (_, i) => user(endpoint, tokens[i], i));
  if (db && opts.writes > 0) tasks.push(writer(db));
  if (opts.burst > 0) {
    const at = forever ? 60_000 : opts.durationMs / 2;
    tasks.push(wait(at).then(() => (stopping ? undefined : burst(endpoint, tokens))));
  }
  if (!forever) setTimeout(stop, opts.durationMs);

  await Promise.all(tasks);
  clearInterval(ticker);
  console.log("final:");
  report(startedAt);

  if (db && !opts.keep) {
    const { rowCount } = await db.query(`DELETE FROM ${SOURCE_TABLE} WHERE owner_id LIKE $1`, [`${USER_PREFIX}%`]);
    console.log(`🧹 deleted ${rowCount} load-user rows`);
  }
}

function stop() {
  if (stopping) return;
  stopping = true;
  console.log("⏹  stopping: closing open streams...");
  for (const ac of open) ac.abort();
}

process.on("SIGINT", () => {
  if (stopping) process.exit(130); // second Ctrl-C: exit without cleanup
  stop();
});

const needsDb = opts.rows > 0 || opts.writes > 0;
if (needsDb) {
  await withTempAccess(async () => {
    const db = await connectWithRetry(adminConfig());
    try {
      await run(db);
    } finally {
      await db.end();
    }
  });
} else {
  await run(null);
}
process.exit(0);
