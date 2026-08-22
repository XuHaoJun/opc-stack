#!/usr/bin/env bash
# Smoke-test a prototype template end to end, against the LIVE stack.
#
#   tests/prototype-template.sh [template] [layer...]
#     tests/prototype-template.sh                 # nextjs, no layers
#     tests/prototype-template.sh nextjs ui       # nextjs + the ui layer
#
# Layers are tested one at a time against the base, never in combination:
# they are required to be independent, so coverage is linear. If a combination
# ever fails, that is a layer breaking the contract, not a gap here.
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
shift || true
LAYERS=("$@")
NAME="tmpl-smoke-${TEMPLATE//[^a-z0-9]/}"
PC="docker compose exec -T paperclip"
# Anything touching the tree or the package store must run as the runtime user.
# A root-run `pnpm add` leaves the store index root-owned and every later
# install by the agent dies with "attempt to write a readonly database" — far
# from the cause. (Found by this script poisoning its own environment.)
PCN="docker compose exec -T -u node paperclip"

pass=0; fail=0
ok()   { echo "PASS  $1"; pass=$((pass+1)); }
assert_eq() {
  local label="$1" want="$2" got="$3"
  [ "$want" = "$got" ] && ok "$label" || bad "$label (want=$want got=$got)"
}
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

paperclip_projects() {
  $PC sh -c 'key=$(cat /paperclip/.opc/board-api.key); cid=$(curl -fsS -H "Authorization: Bearer $key" http://paperclip:3100/api/companies | jq -r ".[0].id"); curl -fsS -H "Authorization: Bearer $key" "http://paperclip:3100/api/companies/$cid/projects"'
}

project_json="$(paperclip_projects | jq -c --arg n "$NAME" '[.[] | select(.name == $n)][0]')"
project_id="$(printf '%s' "$project_json" | jq -r '.id // empty')"
workspace_id="$(printf '%s' "$project_json" | jq -r '(.primaryWorkspace // (.workspaces // [] | map(select(.isPrimary == true))[0])) | .id // empty')"
workspace_cwd="$(printf '%s' "$project_json" | jq -r '(.primaryWorkspace // (.workspaces // [] | map(select(.isPrimary == true))[0])) | .cwd // empty')"
assert_eq "prototype primary workspace directory" "/prototypes/$NAME" "$workspace_cwd"
if [ -n "$project_id" ] && [ -n "$workspace_id" ]; then
  ok "prototype project and primary workspace exist"
else
  bad "prototype project and primary workspace exist"
fi
assert_eq "prototype policy shared mode" "shared_workspace" \
  "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.defaultMode')"
assert_eq "prototype policy serialize" "serialize" \
  "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.sharedWorkspaceConcurrency')"
assert_eq "prototype policy project-primary" "project_primary" \
  "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.workspaceStrategy.type')"
assert_eq "prototype policy default workspace" "$workspace_id" \
  "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.defaultProjectWorkspaceId')"
assert_eq "prototype marker lane" "prototype" \
  "$(printf '%s' "$project_json" | jq -r '(.primaryWorkspace // (.workspaces // [] | map(select(.isPrimary == true))[0])) | .metadata.opcWorkspaceDefaults.lane')"
assert_eq "prototype marker mode" "shared_workspace" \
  "$(printf '%s' "$project_json" | jq -r '(.primaryWorkspace // (.workspaces // [] | map(select(.isPrimary == true))[0])) | .metadata.opcWorkspaceDefaults.mode')"
assert_eq "prototype marker strategy" "project_primary" \
  "$(printf '%s' "$project_json" | jq -r '(.primaryWorkspace // (.workspaces // [] | map(select(.isPrimary == true))[0])) | .metadata.opcWorkspaceDefaults.strategyType')"
assert_eq "prototype marker concurrency" "serialize" \
  "$(printf '%s' "$project_json" | jq -r '(.primaryWorkspace // (.workspaces // [] | map(select(.isPrimary == true))[0])) | .metadata.opcWorkspaceDefaults.sharedWorkspaceConcurrency')"

board_key="$($PC sh -c 'cat /paperclip/.opc/board-api.key' | tr -d '\r\n')"
legacy_metadata="$(printf '%s' "$project_json" | jq -c '
  (.primaryWorkspace // (.workspaces // [] | map(select(.isPrimary == true))[0])).metadata
  | .markerKeep = "yes"
  | .opcWorkspaceDefaults |= del(.sharedWorkspaceConcurrency)
')"
legacy_policy="$(jq -nc --arg workspace "$workspace_id" '{executionWorkspacePolicy:{enabled:true,defaultMode:"shared_workspace",sharedWorkspaceConcurrency:"allow",defaultProjectWorkspaceId:$workspace,workspaceStrategy:{type:"project_primary"}}}')"
curl -fsS -X PATCH -H "Authorization: Bearer $board_key" -H 'Content-Type: application/json' \
  "http://127.0.0.1:3100/api/projects/$project_id" -d "$legacy_policy" >/dev/null
legacy_workspace_payload="$(jq -nc --argjson metadata "$legacy_metadata" '{metadata:$metadata}')"
curl -fsS -X PATCH -H "Authorization: Bearer $board_key" -H 'Content-Type: application/json' \
  "http://127.0.0.1:3100/api/projects/$project_id/workspaces/$workspace_id" -d "$legacy_workspace_payload" >/dev/null
$PC prototype create "$NAME" >/dev/null 2>&1 \
  && ok "prototype legacy marker resume succeeds" \
  || bad "prototype legacy marker resume succeeds"
project_json="$(paperclip_projects | jq -c --arg n "$NAME" '[.[] | select(.name == $n)][0]')"
assert_eq "legacy operator concurrency survives" "allow" \
  "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.sharedWorkspaceConcurrency')"
assert_eq "legacy marker concurrency is augmented" "serialize" \
  "$(printf '%s' "$project_json" | jq -r '(.primaryWorkspace // (.workspaces // [] | map(select(.isPrimary == true))[0])) | .metadata.opcWorkspaceDefaults.sharedWorkspaceConcurrency')"
assert_eq "legacy marker preserves unrelated field" "yes" \
  "$(printf '%s' "$project_json" | jq -r '(.primaryWorkspace // (.workspaces // [] | map(select(.isPrimary == true))[0])) | .metadata.markerKeep')"

board_key="$($PC sh -c 'cat /paperclip/.opc/board-api.key' | tr -d '\r\n')"
override_payload="$(jq -nc --arg workspace "$workspace_id" '{executionWorkspacePolicy:{enabled:true,defaultMode:"isolated_workspace",sharedWorkspaceConcurrency:"allow",defaultProjectWorkspaceId:$workspace,workspaceStrategy:{type:"git_worktree"},workspaceRuntime:{keep:true}}}')"
curl -fsS -X PATCH -H "Authorization: Bearer $board_key" -H 'Content-Type: application/json' \
  "http://127.0.0.1:3100/api/projects/$project_id" -d "$override_payload" >/dev/null
$PC prototype create "$NAME" >/dev/null 2>&1 \
  && ok "prototype resume succeeds with operator override" \
  || bad "prototype resume succeeds with operator override"
project_json="$(paperclip_projects | jq -c --arg n "$NAME" '[.[] | select(.name == $n)][0]')"
assert_eq "prototype workspace directory survives resume" "$workspace_cwd" \
  "$(printf '%s' "$project_json" | jq -r '(.primaryWorkspace // (.workspaces // [] | map(select(.isPrimary == true))[0])) | .cwd // empty')"
assert_eq "prototype workspace ID survives resume" "$workspace_id" \
  "$(printf '%s' "$project_json" | jq -r '(.primaryWorkspace // (.workspaces // [] | map(select(.isPrimary == true))[0])) | .id // empty')"
assert_eq "prototype operator mode survives resume" "isolated_workspace" \
  "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.defaultMode')"
assert_eq "prototype operator concurrency survives resume" "allow" \
  "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.sharedWorkspaceConcurrency')"
assert_eq "prototype operator strategy survives resume" "git_worktree" \
  "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.workspaceStrategy.type')"
assert_eq "prototype operator metadata survives resume" "true" \
  "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.workspaceRuntime.keep')"

PAPERCLIP_API_URL=http://127.0.0.1:3100 PAPERCLIP_API_KEY="$board_key" \
  patches/hermes/opc-paperclip project workspace reset \
    --project-id "$project_id" --lane prototype >/dev/null \
    && ok "prototype policy reset command" || bad "prototype policy reset command"
project_json="$(paperclip_projects | jq -c --arg n "$NAME" '[.[] | select(.name == $n)][0]')"
assert_eq "prototype reset shared mode" "shared_workspace" \
  "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.defaultMode')"
assert_eq "prototype reset serialize" "serialize" \
  "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.sharedWorkspaceConcurrency')"
assert_eq "prototype reset project-primary" "project_primary" \
  "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.workspaceStrategy.type')"
assert_eq "prototype reset workspace remains primary" "$workspace_id" \
  "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.defaultProjectWorkspaceId')"
assert_eq "prototype reset marker lane" "prototype" \
  "$(printf '%s' "$project_json" | jq -r '(.primaryWorkspace // (.workspaces // [] | map(select(.isPrimary == true))[0])) | .metadata.opcWorkspaceDefaults.lane')"
assert_eq "prototype reset marker mode" "shared_workspace" \
  "$(printf '%s' "$project_json" | jq -r '(.primaryWorkspace // (.workspaces // [] | map(select(.isPrimary == true))[0])) | .metadata.opcWorkspaceDefaults.mode')"
assert_eq "prototype reset marker strategy" "project_primary" \
  "$(printf '%s' "$project_json" | jq -r '(.primaryWorkspace // (.workspaces // [] | map(select(.isPrimary == true))[0])) | .metadata.opcWorkspaceDefaults.strategyType')"
assert_eq "prototype reset marker concurrency" "serialize" \
  "$(printf '%s' "$project_json" | jq -r '(.primaryWorkspace // (.workspaces // [] | map(select(.isPrimary == true))[0])) | .metadata.opcWorkspaceDefaults.sharedWorkspaceConcurrency')"
assert_eq "prototype reset preserves unrelated marker field" "yes" \
  "$(printf '%s' "$project_json" | jq -r '(.primaryWorkspace // (.workspaces // [] | map(select(.isPrimary == true))[0])) | .metadata.markerKeep')"

step "install (slow: a cold store fetches the whole tree)"
$PCN sh -c "cd /prototypes/$NAME && pnpm install --silent" >/dev/null 2>&1 \
  && ok "pnpm install" || bad "pnpm install"

for layer in "${LAYERS[@]:-}"; do
  [ -n "$layer" ] || continue
  step "apply layer '$layer'"
  $PC prototype layer add "$NAME" "$layer" 2>&1 | tail -3 | sed 's/^/  /'
  # Each layer declares the file that proves it ran — the same marker its
  # apply.sh uses for its own idempotency guard, so the two cannot disagree.
  case "$layer" in
    ui)   marker=components.json ;;
    auth) marker=lib/auth.js ;;
    *)    marker="" ;;
  esac
  if [ -n "$marker" ]; then
    # Applied as root on purpose: that is how a human runs it, and it must
    # still leave a tree the runtime user can build in.
    $PCN sh -c "cd /prototypes/$NAME && test -f '$marker'" \
      && ok "layer '$layer' applied ($marker)" || bad "layer '$layer' did not apply"
  else
    echo "  (no marker known for '$layer' — add one to this script)"
  fi
done

step "migrate"
$PCN sh -c "cd /prototypes/$NAME && node scripts/migrate.mjs" 2>&1 | sed 's/^/  /' \
  && ok "migrations applied" || bad "migrate"
# Re-run must be a no-op: applied files are recorded, not re-executed.
$PCN sh -c "cd /prototypes/$NAME && node scripts/migrate.mjs" 2>&1 | grep -q "up to date" \
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

for layer in "${LAYERS[@]:-}"; do
  [ "$layer" = auth ] || continue
  step "auth layer: real sign-up over HTTP"
  # The whole point is that the endpoints work before any UI exists.
  body=$(curl -s -w '\n%{http_code}' --max-time 25 -X POST \
    -H "Content-Type: application/json" -H "Origin: $URL" \
    -d '{"email":"smoke@test.invalid","password":"hunter2hunter2","name":"Smoke"}' \
    "$URL/api/auth/sign-up/email")
  code=$(echo "$body" | tail -1)
  [ "$code" = 200 ] && ok "sign-up 200" || { bad "sign-up returned $code"; echo "$body" | head -2 | sed 's/^/    /'; }
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 -X POST \
    -H "Content-Type: application/json" -H "Origin: $URL" \
    -d '{"email":"smoke@test.invalid","password":"hunter2hunter2"}' \
    "$URL/api/auth/sign-in/email")
  [ "$code" = 200 ] && ok "sign-in 200" || bad "sign-in returned $code"
done

for layer in "${LAYERS[@]:-}"; do
  [ "$layer" = ui ] || continue
  step "ui layer serves compiled CSS"
  css=$(curl -s --max-time 10 -H "Origin: $URL" "$URL/" | grep -oE '/_next/static/[^"]*\.css' | head -1)
  if [ -n "$css" ]; then
    bytes=$(curl -s --max-time 10 -H "Origin: $URL" "$URL$css" | wc -c)
    [ "$bytes" -gt 5000 ] && ok "tailwind css served ($bytes bytes)" \
      || bad "stylesheet is only $bytes bytes — globals.css probably not imported"
  else
    bad "no stylesheet linked — app/layout.jsx is not importing globals.css"
  fi
done

step "backends reachable from the running app"
health=$(curl -s --max-time 15 -H "Origin: $URL" "$URL/api/health")
echo "  $health"
echo "$health" | grep -q '"ok":true' && ok "health ok" || bad "health not ok"
echo "$health" | grep -q '"postgres":{"ok":true' && ok "postgres reachable" || bad "postgres unreachable"
echo "$health" | grep -q '"cache":{"ok":true'    && ok "valkey reachable"   || bad "valkey unreachable"

echo
echo "result: $pass pass, $fail fail"
[ "$fail" -eq 0 ]
