// Proves both backends are actually reachable from the running app. The
// fastest way to tell whether a change broke the wiring or the feature.
import { pool } from "../../../lib/db.mjs";
import { valkey } from "../../../lib/valkey.mjs";

export const dynamic = "force-dynamic";

async function check(fn) {
  try {
    return { ok: true, detail: await fn() };
  } catch (err) {
    return { ok: false, detail: String(err?.message ?? err) };
  }
}

export async function GET() {
  const [postgres, cache] = await Promise.all([
    check(async () => {
      const { rows } = await pool.query("SELECT count(*)::int AS n FROM schema_migrations");
      return `${rows[0].n} migration(s) applied`;
    }),
    check(async () => {
      const key = "health:ping";
      await valkey.set(key, String(Date.now()), "EX", 60);
      return `round-trip ok (db ${new URL(process.env.VALKEY_URL).pathname.slice(1) || "0"})`;
    }),
  ]);

  return Response.json(
    { ok: postgres.ok && cache.ok, postgres, cache },
    { status: postgres.ok && cache.ok ? 200 : 503 },
  );
}
