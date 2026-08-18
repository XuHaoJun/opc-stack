#!/bin/sh
# ui layer — Tailwind 4 + shadcn/ui. Runs with cwd = the prototype root, as the
# runtime user.
#
# This is a script rather than a directory of files on purpose: shadcn and
# Tailwind ship their own installers, and copying a snapshot of their output
# would freeze versions we do not control and cannot keep current. What is
# worth recording is the ORDER, and the two steps their installers do not do.
set -eu

if [ -f components.json ]; then
    echo "[ui] already applied (components.json exists) — nothing to do"
    exit 0
fi
[ -f package.json ] || { echo "[ui] no package.json — apply the nextjs base first" >&2; exit 2; }

echo "[ui] installing tailwind 4"
pnpm add -s tailwindcss @tailwindcss/postcss postcss

# Tailwind 4 is a PostCSS plugin; there is no tailwind.config.js any more.
if [ ! -f postcss.config.mjs ]; then
    cat > postcss.config.mjs <<'EOF'
const config = { plugins: { "@tailwindcss/postcss": {} } };
export default config;
EOF
fi

# shadcn writes imports like `@/lib/utils`. Without this alias its own
# generated components fail to resolve, which reads as a bug in shadcn.
if [ ! -f jsconfig.json ] && [ ! -f tsconfig.json ]; then
    cat > jsconfig.json <<'EOF'
{
  "compilerOptions": {
    "paths": { "@/*": ["./*"] }
  }
}
EOF
fi

# Must exist before init: shadcn appends its theme to this file.
mkdir -p app
[ -f app/globals.css ] || printf '@import "tailwindcss";\n' > app/globals.css

echo "[ui] shadcn init"
# -d --yes takes defaults and skips prompts, but it still asks before
# overwriting an existing components.json — which is why the guard above exits
# early instead of letting this block forever on a re-run.
npx --yes shadcn@latest init -d --yes

# shadcn does NOT do this, and without it everything installs successfully,
# reports success, and renders with no styling at all.
if [ -f app/layout.jsx ] && ! grep -q 'globals.css' app/layout.jsx; then
    printf 'import "./globals.css";\n\n%s' "$(cat app/layout.jsx)" > app/layout.jsx.new
    mv app/layout.jsx.new app/layout.jsx
    echo "[ui] imported globals.css into app/layout.jsx"
fi

echo "[ui] done — add components as you need them: npx shadcn@latest add card input"
