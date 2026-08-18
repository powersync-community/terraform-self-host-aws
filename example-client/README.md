# example-client

Companion toolkit for the [`infra/`](../infra) deployment: seed the Postgres database, mint a client
token, run a minimal React client, and verify least-privilege scoping. It reads everything it needs
from the Terraform outputs, so it survives `destroy`/`apply` with no hand-editing.

Nothing here is deployed. The token is minted **locally**, and the seed/verify scripts reach RDS by
temporarily authorizing your public IP on the database security group (added and auto-removed). The
React client never touches the database directly — it syncs through the public ALB.

## Commands

| Command | What it does |
|---|---|
| `npm run seed` | Create the demo `lists` table (if needed) and load a small dataset owned by two users. |
| `npm run clear` | Drop the `lists` table. |
| `npm run token` | Mint a 12h RS256 JWT (key from Secrets Manager) for `example-user` → writes `web/.env.local`. |
| `npm run dev` | `token` + start the React client (`web/`). |
| `npm run test:least-privilege` | Assert the source role is read-only and cannot reach the storage database. |

## Prerequisites

- `infra/` applied; your shell has `.env` loaded (needs AWS creds and, for RDS reachability,
  `TF_VAR_admin_cidr` set to your IP — or the scripts' temporary allowlist will add it).
- Node ≥ 20 and `terraform` on PATH (the scripts read `terraform output`).
- `npm install` (here) and `npm install --prefix web`.

## 1. Seed the database

```bash
npm run seed
```

Creates `lists` and inserts rows for two users: `example-user` (which the minted token syncs) and
`someone-else` (which it must **not** — demonstrating the per-user sync rule). Re-run any time; it
truncates and re-inserts. The replicator picks up the change within a few seconds.

## 2. Mint a token + run the client

```bash
npm run dev            # = npm run token (writes web/.env.local) + vite dev server
# first time only:
npm install --prefix web
```

The page connects to the deployed PowerSync ALB and live-renders the `lists` synced for your user.
**Seeing your seeded rows in the browser proves the full path — Postgres → replicator → bucket
storage → sync API → client.**

## 3. (Optional) Verify least-privilege

```bash
npm run test:least-privilege
```

Connects as the restricted `powersync_source` role and asserts: it can read the source `lists`
table, it is **denied** writing to it (replication only reads), and it **cannot reach** the bucket
storage database at all.

## Notes

- The demo syncs the `lists` table per user via `owner_id = request.user_id()` (sync rules in
  `../infra/locals.tf`). To sync your own tables, change the sync rules, the seed data, and the
  client schema in `web/src/powersync.ts` together.
- The token subject is `example-user`; it must match the `owner_id` the seed script writes.
- Tokens are valid 12h — re-run `npm run token` (or `npm run dev`) when one expires.
- Real client apps upload writes to your own backend API (PowerSync's `uploadData`); this example is
  read-only, so there is no backend and `uploadData` is a no-op.
