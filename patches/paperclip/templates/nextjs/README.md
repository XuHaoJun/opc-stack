# nextjs — Next.js + Postgres (raw SQL) + Valkey

Base template for a prototype. Everything below is already wired and verified;
you should not have to think about any of it.

```
pnpm install
node scripts/migrate.mjs
prototype expose <name> --command "node scripts/dev.mjs" --start
```

Then open `DEV_URL` from `.env` and check `/` — it reports whether Postgres and
Valkey are actually reachable, which is the fastest way to know the wiring
survived whatever you changed.

## What is wired

| File | Why it is not obvious |
|---|---|
| `lib/env.mjs` | `.env` values **overwrite** ambient ones. The harness injects the execution workspace's lease, which is a *different* tenant's — trusting the ambient env silently talks to the wrong database. |
| `scripts/dev.mjs` | `DEV_PORT` wins over `PORT` (ambient `PORT` is 3100, the Paperclip API), and it deletes `NODE_ENV` because the harness exports `production` and `next dev` refuses to be a dev server under it. Binds `0.0.0.0`. |
| `next.config.mjs` | `allowedDevOrigins` from `DEV_HOST`. Next 16 returns **403 for any request carrying an `Origin` header** when the host is not localhost — including same-origin ones. Without this the page loads and every chunk fails. |
| `lib/valkey.mjs` | `enableReadyCheck: false`. The lease ACL blocks `INFO` (admin category) and the ready check uses it, so the client never becomes ready. |
| `scripts/migrate.mjs` | `migrations/*.sql` in filename order, one transaction each, recorded in `schema_migrations`. Re-runnable. |

## Adding a migration

Drop `migrations/0002_whatever.sql` and re-run `node scripts/migrate.mjs`.
Applied files are never re-applied; edit a file that already ran and it will be
skipped, so make a new one instead.

## Raw SQL, no ORM

`lib/db.mjs` exports a `pg` pool. Use parameterised queries (`$1`). This is a
deliberate choice for prototypes — see the ticket if it says otherwise.
