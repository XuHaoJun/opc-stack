// Applies migrations/*.sql in filename order, one transaction each, recording
// applied files in schema_migrations. Re-runnable: applied files are skipped.
//
//   node scripts/migrate.mjs
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import pg from "pg";
import { ensureEnv } from "../lib/env.mjs";

ensureEnv();

const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
await client.connect();

await client.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
  filename   text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
)`);

const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "migrations");
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const applied = new Set(
  (await client.query(`SELECT filename FROM schema_migrations`)).rows.map((r) => r.filename),
);

let count = 0;
for (const f of files) {
  if (applied.has(f)) {
    console.log(`skip  ${f}`);
    continue;
  }
  const sql = readFileSync(join(dir, f), "utf8");
  // One transaction per file: a failure rolls that file back entirely and
  // aborts, so a half-applied migration is never recorded as applied.
  await client.query("BEGIN");
  try {
    await client.query(sql);
    await client.query(`INSERT INTO schema_migrations (filename) VALUES ($1)`, [f]);
    await client.query("COMMIT");
    console.log(`apply ${f}`);
    count++;
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  }
}
console.log(count ? `migrated ${count} file(s)` : "up to date");
await client.end();
