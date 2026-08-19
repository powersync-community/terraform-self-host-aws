import { useEffect } from "react";
import { PowerSyncContext, useStatus, useQuery } from "@powersync/react";
import { db } from "./powersync";
import { connector } from "./connector";

type ListRow = { id: string; name: string | null; created_at: string | null };

export default function App() {
  useEffect(() => {
    db.connect(connector).catch((e) => console.error("connect failed", e));
    return () => {
      db.disconnect().catch(() => {});
    };
  }, []);

  return (
    <PowerSyncContext.Provider value={db}>
      <main style={{ fontFamily: "system-ui, sans-serif", padding: 24, maxWidth: 640, margin: "0 auto" }}>
        <h1>PowerSync on AWS (demo)</h1>
        <StatusBar />
        <Lists />
      </main>
    </PowerSyncContext.Provider>
  );
}

function StatusBar() {
  const status = useStatus();
  const dot = status.connected ? "🟢 connected" : status.connecting ? "🟡 connecting…" : "🔴 disconnected";
  return (
    <p style={{ fontSize: 14, color: "#555" }}>
      <strong>Sync:</strong> {dot}
      {" · "}
      {status.hasSynced ? "initial sync done" : "waiting for first sync…"}
      {status.lastSyncedAt && ` · last ${status.lastSyncedAt.toLocaleTimeString()}`}
    </p>
  );
}

function Lists() {
  const { data: lists, isLoading } = useQuery<ListRow>("SELECT * FROM lists ORDER BY name");

  if (isLoading) return <p>Loading lists…</p>;
  if (!lists.length) return <p>No lists synced yet. Seed the cluster, then watch them appear here.</p>;

  return (
    <>
      <p>
        <strong>{lists.length}</strong> list(s) synced for your user:
      </p>
      <ul>
        {lists.map((l) => (
          <li key={l.id}>{l.name ?? <em>(no name)</em>}</li>
        ))}
      </ul>
    </>
  );
}
