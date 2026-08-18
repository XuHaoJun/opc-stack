#!/bin/sh
# auth layer — better-auth over the base's raw pg pool. cwd = prototype root,
# running as the runtime user.
set -eu

if [ -f lib/auth.js ]; then
    echo "[auth] already applied (lib/auth.js exists) — nothing to do"
    exit 0
fi
[ -f package.json ] || { echo "[auth] no package.json — apply the nextjs base first" >&2; exit 2; }
[ -f lib/db.mjs ]   || { echo "[auth] lib/db.mjs missing — this layer needs the nextjs base" >&2; exit 2; }

echo "[auth] installing better-auth"
pnpm add -s better-auth

# Independent of the ui layer by design: both ensure this alias, neither
# depends on the other having run. A layer that required another to go first
# would make coverage combinatorial.
if [ ! -f jsconfig.json ] && [ ! -f tsconfig.json ]; then
    cat > jsconfig.json <<'EOF'
{
  "compilerOptions": {
    "paths": { "@/*": ["./*"] }
  }
}
EOF
fi

# Secret: generated once and kept in .env (gitignored, survives re-provision).
if ! grep -q '^BETTER_AUTH_SECRET=' .env 2>/dev/null; then
    printf 'BETTER_AUTH_SECRET=%s\n' \
        "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" >> .env
fi
# Without an explicit base URL better-auth derives the origin from the incoming
# request and warns that callbacks and redirects may not work.
if ! grep -q '^BETTER_AUTH_URL=' .env 2>/dev/null; then
    printf 'BETTER_AUTH_URL=%s\n' "$(sed -n 's/^DEV_URL=//p' .env)" >> .env
fi

mkdir -p lib "app/api/auth/[...all]"

cat > lib/auth.js <<'EOF'
// better-auth on the base's raw pg pool — no ORM. better-auth accepts a `pg`
// Pool directly for its Postgres adapter; the drizzle/prisma layer that most
// tutorials add is not required and would duplicate lib/db.mjs.
import { betterAuth } from "better-auth";
import { pool } from "./db.mjs";
import { ensureEnv } from "./env.mjs";

ensureEnv();

export const auth = betterAuth({
  database: pool,
  baseURL: process.env.BETTER_AUTH_URL,
  secret: process.env.BETTER_AUTH_SECRET,
  emailAndPassword: { enabled: true },
});
EOF

cat > "app/api/auth/[...all]/route.js" <<'EOF'
import { auth } from "../../../../lib/auth.js";
import { toNextJsHandler } from "better-auth/next-js";

export const { POST, GET } = toNextJsHandler(auth);
EOF

cat > lib/auth-client.js <<'EOF'
// No baseURL on purpose: the client defaults to the current origin, which is
// correct wherever the preview happens to be published — hardcoding one breaks
// the moment the host changes.
import { createAuthClient } from "better-auth/react";

export const { signIn, signUp, signOut, useSession, getSession } =
  createAuthClient();
EOF

# The schema becomes an ordinary numbered migration rather than a second,
# parallel mechanism: same runner, same schema_migrations bookkeeping.
mkdir -p migrations
next_n=$(ls migrations 2>/dev/null | sed -n 's/^\([0-9]\{4\}\)_.*\.sql$/\1/p' | sort -n | tail -1)
next_n=$(printf '%04d' $(( ${next_n:-0} + 1 )))
echo "[auth] generating schema → migrations/${next_n}_auth.sql"
npx --yes @better-auth/cli@latest generate \
    --config lib/auth.js --output "migrations/${next_n}_auth.sql" --yes >/dev/null 2>&1 \
  || { echo "[auth] schema generation failed" >&2; exit 1; }
[ -s "migrations/${next_n}_auth.sql" ] || { echo "[auth] generated schema is empty" >&2; exit 1; }

echo "[auth] done — run: node scripts/migrate.mjs"
