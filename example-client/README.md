# example-client

Companion toolkit for the [`infra/`](../infra) deployment. It bootstraps the Postgres database, seeds
it, mints a client token, runs a minimal React client, and checks least-privilege scoping. It reads
what it needs from the Terraform outputs, so it survives `destroy`/`apply` with no hand-editing.

Nothing here is deployed. The token is minted locally, and the bootstrap/seed scripts reach RDS by
temporarily authorizing your public IP on the database security group, then removing it. The React
client never touches the database; it syncs through the public ALB.

## Commands

| Command | What it does |
|---|---|
| `npm run bootstrap` | One time after `terraform apply`: create PowerSync's DB roles, the `powersync` publication, the bucket-storage database, and source-read grants (idempotent). |
| `npm run seed` | Create the demo `lists` table (if needed) and load a small dataset owned by two users. |
| `npm run clear` | Drop the `lists` table. |
| `npm run token` | Mint a 12h RS256 JWT (key from Secrets Manager) for `example-user`, writing `web/.env.local`. |
| `npm run connect` | Headless client: connect to the deployed endpoint, wait for the first sync, and print the synced `lists` rows. Verifies sync without a browser. |
| `npm run dev` | `token` plus the React client (`web/`). |
| `npm run test:least-privilege` | Check that the source role is read-only and cannot reach the storage database. |

## Prerequisites

- `infra/` applied, with `.env` loaded (AWS creds, and `TF_VAR_admin_cidr` set to your IP so the
  scripts can reach RDS; the temporary allowlist adds it if not).
- Node 20+ and `terraform` on PATH (the scripts read `terraform output`).
- `npm install` (here) and `npm install --prefix web`.

## 1. Bootstrap the database (one time, after apply)

```bash
npm run bootstrap
```

Creates the two least-privilege roles, the `powersync` publication, the bucket-storage database, and
the source-read grants, using the `pg` driver as the RDS master and reading everything from
`terraform output`. It is idempotent. Run it once after `terraform apply`; the ECS services stay in a
retry loop until it finishes, then go healthy.

## 2. Seed the database

```bash
npm run seed
```

Creates `lists` and inserts rows for two users: `example-user`, which the minted token syncs, and
`someone-else`, which it does not (that is the per-user sync rule at work). Re-run any time; it
truncates and re-inserts. The replicator picks up the change within a few seconds.

## 3. Mint a token and run the client

```bash
npm run dev            # runs `token` (writes web/.env.local), then the vite dev server
# first time only:
npm install --prefix web
```

The page connects to the deployed PowerSync ALB and renders the `lists` synced for your user. Seeing
your seeded rows in the browser confirms the path from Postgres through the replicator, bucket
storage, and sync API to the client.

Prefer the terminal? `npm run connect` does the same end to end without a browser: it mints a token,
connects a headless PowerSync client, waits for the first sync, and prints the synced `lists` rows.
It is the quickest way to confirm sync works, and connecting it makes the `concurrent_connections`
metric and the client-sync dashboard panels go non-zero.

## 4. (Optional) Check least-privilege

```bash
npm run test:least-privilege
```

Connects as the restricted `powersync_source` role and checks three things: it can read the source
`lists` table, it is denied writing to it (replication only reads), and it cannot reach the bucket
storage database.

## Notes

- The demo syncs `lists` per user via `owner_id = request.user_id()` (sync rules in
  `../infra/locals.tf`). To sync your own tables, change the sync rules, the seed data, and the client
  schema in `web/src/powersync.ts` together.
- The token subject is `example-user`, which must match the `owner_id` the seed script writes.
- Tokens last 12h; re-run `npm run token` (or `npm run dev`) when one expires.
- Real apps upload writes to their own backend API (PowerSync's `uploadData`). This example is
  read-only, so it has no backend and `uploadData` is a no-op.
