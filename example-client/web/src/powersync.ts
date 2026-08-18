import { column, Schema, Table, PowerSyncDatabase } from "@powersync/web";

// Client-side schema: which columns of the synced `lists` rows to materialize locally.
// The sync rule syncs the current user's rows (SELECT * FROM lists WHERE owner_id = user_id),
// so all columns arrive; declare the ones we render. `id` is always present implicitly.
export const schema = new Schema({
  lists: new Table({
    owner_id: column.text,
    name: column.text,
    created_at: column.text,
  }),
});

export const db = new PowerSyncDatabase({
  schema,
  database: { dbFilename: "powersync.db" },
});
