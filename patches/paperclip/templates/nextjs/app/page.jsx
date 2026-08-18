// Landing page: shows whether the wiring is live. Replace it with the actual
// prototype — but keep /api/health, it costs nothing and answers "is it my
// code or is it the plumbing?" immediately.
import { headers } from "next/headers";

export const dynamic = "force-dynamic";

async function readHealth() {
  const h = await headers();
  const host = h.get("host");
  try {
    const res = await fetch(`http://127.0.0.1:${process.env.DEV_PORT || 3000}/api/health`, {
      cache: "no-store",
    });
    return { host, body: await res.json() };
  } catch (err) {
    return { host, body: { ok: false, error: String(err?.message ?? err) } };
  }
}

export default async function Page() {
  const { host, body } = await readHealth();
  const row = (label, r) => (
    <li>
      <strong>{label}</strong>: {r?.ok ? "✅" : "❌"} <code>{r?.detail}</code>
    </li>
  );
  return (
    <main style={{ maxWidth: "42rem" }}>
      <h1>prototype</h1>
      <p>
        Served from <code>{host}</code>. Backends leased by devenv:
      </p>
      <ul>
        {row("postgres", body.postgres)}
        {row("valkey", body.cache)}
      </ul>
      <p style={{ color: "#666" }}>
        Replace <code>app/page.jsx</code> with the real thing. Add schema under{" "}
        <code>migrations/</code> and run <code>node scripts/migrate.mjs</code>.
      </p>
    </main>
  );
}
