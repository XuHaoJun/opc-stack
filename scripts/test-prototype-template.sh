#!/usr/bin/env bash
# Smoke-test a prototype template end to end, against the LIVE stack.
#
#   scripts/test-prototype-template.sh [template]     # default: nextjs
#
# Why this exists: a template is code that nobody runs until an agent depends
# on it. When it rots (a major Next release, a changed peer dep) the failure
# lands mid-ticket and reads as "the prototype failed" — the agent then fights
# the scaffold instead of building. This turns that into a loud, local failure.
#
# It creates a throwaway prototype, installs, migrates, serves, checks both
# backends through HTTP, and destroys it. Exit 0 = the template still works.
set -uo pipefail
cd "$(dirname "$0")/.."

TEMPLATE="${1:-nextjs}"
NAME="tmpl-smoke-${TEMPLATE//[^a-z0-9]/}"
PC="docker compose exec -T paperclip"

pass=0; fail=0
ok()   { echo "PASS  $1"; pass=$((pass+1)); }
bad()  { echo "FAIL  $1"; fail=$((fail+1)); }
step() { echo; echo "── $1 ──"; }

cleanup() {
  step "cleanup"
  echo "$NAME" | $PC prototype destroy "$NAME" >/dev/null 2>&1 \
    && echo "removed $NAME" || echo "nothing to remove"
}
trap cleanup EXIT

step "scaffold from template '$TEMPLATE'"
$PC prototype create "$NAME" --template "$TEMPLATE" 2>&1 | sed 's/^/  /' \
  && ok "create --template" || bad "create --template"

URL="$($PC sh -c "sed -n 's/^DEV_URL=//p' /prototypes/$NAME/.env" | tr -d '\r\n')"
[ -n "$URL" ] && ok "lease issued DEV_URL ($URL)" || { bad "no DEV_URL"; exit 1; }

step "install (slow: a cold store fetches the whole tree)"
$PC sh -c "cd /prototypes/$NAME && pnpm install --silent" >/dev/null 2>&1 \
  && ok "pnpm install" || bad "pnpm install"

step "migrate"
$PC sh -c "cd /prototypes/$NAME && node scripts/migrate.mjs" 2>&1 | sed 's/^/  /' \
  && ok "migrations applied" || bad "migrate"
# Re-run must be a no-op: applied files are recorded, not re-executed.
$PC sh -c "cd /prototypes/$NAME && node scripts/migrate.mjs" 2>&1 | grep -q "up to date" \
  && ok "migrate is re-runnable" || bad "migrate re-run was not a no-op"

step "serve"
$PC prototype expose "$NAME" --command "node scripts/dev.mjs" --start 2>&1 | sed 's/^/  /'
for _ in $(seq 1 60); do curl -sf -o /dev/null --max-time 3 "$URL/" && break; sleep 3; done

# WITH an Origin header — that is the case Next 16 rejects, and the case a
# browser always produces. Testing without it passes on a broken config.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Origin: $URL" "$URL/")
[ "$code" = 200 ] && ok "page 200 with Origin header" || bad "page returned $code with Origin (allowedDevOrigins?)"

chunk=$(curl -s --max-time 10 "$URL/" | grep -oE '/_next/static/chunks/[A-Za-z0-9_./-]+\.js' | head -1)
if [ -n "$chunk" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Origin: $URL" "$URL$chunk")
  [ "$code" = 200 ] && ok "static chunk 200 with Origin" || bad "chunk returned $code"
fi

step "backends reachable from the running app"
health=$(curl -s --max-time 15 -H "Origin: $URL" "$URL/api/health")
echo "  $health"
echo "$health" | grep -q '"ok":true' && ok "health ok" || bad "health not ok"
echo "$health" | grep -q '"postgres":{"ok":true' && ok "postgres reachable" || bad "postgres unreachable"
echo "$health" | grep -q '"cache":{"ok":true'    && ok "valkey reachable"   || bad "valkey unreachable"

echo
echo "result: $pass pass, $fail fail"
[ "$fail" -eq 0 ]
