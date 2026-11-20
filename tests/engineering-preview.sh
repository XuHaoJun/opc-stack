#!/usr/bin/env bash
# Live gate: a code ticket's preview, end to end, with no LLM call.
#
#   fixture git repo (its .paperclip/preview serves a random marker)
#   → Paperclip project (isolated git worktrees) + test-owned `process` agent
#   → issue assigned to that agent; its run realizes the execution workspace
#     and hands off (in_review, assigned to the owner) with its own run key
#   → `opc-paperclip preview up` inside frontdoor (as the agent uid, board key)
#     while the hand-off run is still finishing
#   → the URL serves the marker from the host
#   → PATCH status:"done" → event-bridge stops the preview within three poll
#     intervals → the port is free again (no running preview holds it, nothing
#     answers on it)
#
# The process adapter is the technique of tests/paperclip-workspace-routing.sh
# --live: Paperclip realizes the worktree for the run, the script exits 0, no
# model is called. Agents with runs cannot be deleted (DELETE /agents/:id 500s
# on v2026.1106.0, see AGENTS.md), so the test agent is terminated and left.
#
#   --keep   leave the issue, workspace, project and agent in place (for the
#            manual recreate/reopen checks); the preview itself is still
#            stopped by the gate.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/load-env.sh; opc_load_env ./.env

KEEP=0
case "${1-}" in
  "") ;;
  --keep) KEEP=1 ;;
  *) echo "usage: $0 [--keep]" >&2; exit 2 ;;
esac

PASS=0 FAIL=0
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }

MARKER="opc-preview-gate-$RANDOM-$(date +%s)-$$"
BASE="http://127.0.0.1:${PAPERCLIP_PORT:-3100}/api"
FIXTURE_ROOT=/paperclip/opc-test-fixtures
FIXTURE="$FIXTURE_ROOT/$MARKER"
ADAPTER="$FIXTURE_ROOT/$MARKER-agent.sh"
KEY="" COMPANY="" PROJECT="" AGENT="" ISSUE="" IDENT="" WS="" PORT_USED=""
BODY="" STATUS=""

api() { # METHOD PATH [JSON] → BODY/STATUS, 0 on 2xx
  local out code
  out="$(mktemp)"
  if [ -n "${3-}" ]; then
    code="$(curl -sS -o "$out" -w '%{http_code}' -X "$1" -H "Authorization: Bearer $KEY" \
      -H 'Content-Type: application/json' --data-binary "$3" "$BASE$2")" || code=000
  else
    code="$(curl -sS -o "$out" -w '%{http_code}' -X "$1" -H "Authorization: Bearer $KEY" "$BASE$2")" || code=000
  fi
  BODY="$(cat "$out")"; rm -f "$out"; STATUS="$code"
  case "$code" in 2??) return 0 ;; *) return 1 ;; esac
}
in_paperclip() { docker compose exec -T -u node paperclip sh -c "$1"; }
fd_paperclip() { docker compose exec -T -u 10000 frontdoor opc-paperclip "$@"; }

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  echo "── cleanup ──"
  if [ -n "$IDENT" ]; then
    fd_paperclip preview down --issue "$IDENT" >/dev/null 2>&1 \
      && ok "cleanup: preview down $IDENT" || bad "cleanup: preview down $IDENT"
  fi
  if [ "$KEEP" -eq 1 ]; then
    echo "KEEP  issue=$IDENT ($ISSUE) workspace=$WS project=$PROJECT agent=$AGENT fixture=$FIXTURE"
  else
    if [ -n "$ISSUE" ] && api GET "/issues/$ISSUE"; then
      case "$(printf '%s' "$BODY" | jq -r .status)" in
        done|cancelled) ;;
        *) api PATCH "/issues/$ISSUE" '{"status":"cancelled"}' \
             && ok "cleanup: cancel $IDENT" || bad "cleanup: cancel $IDENT (HTTP $STATUS)" ;;
      esac
    fi
    if [ -n "$AGENT" ]; then
      api POST "/agents/$AGENT/terminate" '{}' \
        && ok "cleanup: terminate test agent" || bad "cleanup: terminate test agent (HTTP $STATUS)"
    fi
    if [ -n "$WS" ]; then
      local tries=0
      until api PATCH "/execution-workspaces/$WS" '{"status":"archived"}'; do
        tries=$((tries+1)); [ "$tries" -ge 30 ] && break; sleep 1
      done
      [ "$tries" -lt 30 ] && ok "cleanup: archive execution workspace" \
        || bad "cleanup: archive execution workspace (HTTP $STATUS)"
    fi
    if [ -n "$PROJECT" ]; then
      # Paperclip refuses to delete a project that still governs retained task
      # workspaces until it is archived. Archived is the floor; delete is a bonus.
      api PATCH "/projects/$PROJECT" "$(jq -nc --arg t "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" '{archivedAt:$t}')" \
        && ok "cleanup: archive test project" || bad "cleanup: archive test project (HTTP $STATUS)"
      api DELETE "/projects/$PROJECT" && ok "cleanup: delete test project" \
        || echo "INFO  archived test project $PROJECT kept (DELETE HTTP $STATUS)"
    fi
    # The fixture repo is the archived project's base checkout; its worktree
    # went with the archived execution workspace.
    in_paperclip "rm -rf '$ADAPTER' '$FIXTURE'" || true
  fi
  # Nothing of ours may still hold a preview port.
  if [ -n "$PORT_USED" ]; then
    if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$PORT_USED/"; then
      bad "cleanup: port $PORT_USED still answers"
    else
      ok "cleanup: port $PORT_USED answers nothing"
    fi
  fi
  echo
  echo "result: $PASS pass, $FAIL fail"
  [ "$FAIL" -eq 0 ] && [ "$rc" -eq 0 ] && exit 0
  exit 1
}
trap cleanup EXIT INT TERM

echo "── preflight ──"
KEY="$(docker compose exec -T paperclip cat /paperclip/.opc/board-api.key | tr -d '\r\n')"
[ -n "$KEY" ] && ok "board key" || { bad "board key"; exit 1; }
api GET /companies && COMPANY="$(printf '%s' "$BODY" | jq -r 'if length == 1 then .[0].id else empty end')"
[ -n "$COMPANY" ] && ok "one company" || { bad "one company"; exit 1; }
POLL="$(docker compose exec -T event-bridge sh -c 'printf %s "${OPC_EVENT_POLL_INTERVAL:-7}"')"
POLL="${POLL%.*}"; [ -n "$POLL" ] || POLL=7
in_paperclip 'command -v python3 >/dev/null && command -v opc-preview-run >/dev/null' \
  && ok "paperclip image has python3 + opc-preview-run" \
  || { bad "paperclip image has python3 + opc-preview-run"; exit 1; }

echo "── fixture repo ──"
# `exec` keeps the server as the runtime service's own process; the server
# binds exactly the port Paperclip assigned and the host it was given.
if in_paperclip "set -e
  mkdir -p '$FIXTURE/.paperclip'
  cd '$FIXTURE'
  git init -q -b main .
  printf '<!doctype html><title>gate</title><p>%s</p>\n' '$MARKER' > index.html
  printf '#!/bin/sh\nexec python3 -m http.server \"\$PORT\" --bind \"\$HOST\"\n' > .paperclip/preview
  chmod 755 .paperclip/preview
  git add -A
  git -c user.name=opc-gate -c user.email=gate@opc.local commit -q -m 'preview gate fixture'"; then
  ok "fixture repo with executable .paperclip/preview"
else
  bad "fixture repo"; exit 1
fi
# The test agent hands off exactly as the Fullstack Engineer is told to for a
# preview ticket — with its own run key — and then keeps its run alive a few
# seconds, so `preview up` lands while the hand-off run is still finishing.
cat <<'AGENT' | in_paperclip "cat > '$ADAPTER' && chmod 755 '$ADAPTER'" || { bad "install test agent script"; exit 1; }
#!/bin/sh
api="${PAPERCLIP_API_URL%/}"; api="${api%/api}/api"
auth="Authorization: Bearer $PAPERCLIP_API_KEY"
issue="${PAPERCLIP_TASK_ID:-$1}"
owner="$(curl -fsS -H "$auth" "$api/issues/$issue" | jq -r '.createdByUserId // empty')"
curl -fsS -X PATCH -H "$auth" -H 'Content-Type: application/json' \
  --data-binary "$(jq -nc --arg u "$owner" '{status:"in_review",assigneeUserId:$u,assigneeAgentId:null}')" \
  "$api/issues/$issue" >/dev/null
sleep 5
AGENT

echo "── project, agent, issue ──"
payload="$(jq -nc --arg n "$MARKER" --arg cwd "$FIXTURE" '
  {name:$n, description:"engineering-preview gate fixture (safe to delete)", status:"in_progress",
   executionWorkspacePolicy:{enabled:true, defaultMode:"isolated_workspace",
     workspaceStrategy:{type:"git_worktree"}},
   workspace:{name:"primary", sourceType:"local_path", cwd:$cwd, isPrimary:true}}')"
api POST "/companies/$COMPANY/projects" "$payload" || { bad "create project (HTTP $STATUS: $BODY)"; exit 1; }
PROJECT="$(printf '%s' "$BODY" | jq -r .id)"
PWS="$(printf '%s' "$BODY" | jq -r '(.primaryWorkspace.id // ((.workspaces // [])[] | select(.isPrimary) | .id)) // empty' | head -n1)"
[ -n "$PWS" ] || { bad "project has a primary workspace"; exit 1; }
policy="$(printf '%s' "$BODY" | jq -c --arg w "$PWS" '.executionWorkspacePolicy + {defaultProjectWorkspaceId:$w}')"
api PATCH "/projects/$PROJECT" "$(jq -nc --argjson p "$policy" '{executionWorkspacePolicy:$p}')" \
  && ok "project uses isolated git worktrees" || { bad "bind project policy (HTTP $STATUS)"; exit 1; }

# Issue first (unassigned), so the agent can be told its issue id: the process
# adapter does not export PAPERCLIP_TASK_ID. Assigning it is what wakes the run.
payload="$(jq -nc --arg p "$PROJECT" --arg w "$PWS" --arg m "$MARKER" '
  {title:("preview gate " + $m), description:($m + " engineering preview gate"), status:"todo",
   projectId:$p, projectWorkspaceId:$w, executionWorkspaceSettings:{mode:"inherit"}}')"
api POST "/companies/$COMPANY/issues" "$payload" || { bad "create issue (HTTP $STATUS: $BODY)"; exit 1; }
ISSUE="$(printf '%s' "$BODY" | jq -r .id)"
IDENT="$(printf '%s' "$BODY" | jq -r .identifier)"
ok "issue $IDENT"

payload="$(jq -nc --arg n "$MARKER-agent" --arg cmd "$ADAPTER" --arg i "$ISSUE" '
  {name:$n, role:"general", adapterType:"process",
   adapterConfig:{command:$cmd, args:[$i], timeoutSec:60},
   runtimeConfig:{heartbeat:{enabled:false, maxConcurrentRuns:1}},
   metadata:{opcEngineeringPreviewTest:true}}')"
api POST "/companies/$COMPANY/agents" "$payload" || { bad "create process agent (HTTP $STATUS: $BODY)"; exit 1; }
AGENT="$(printf '%s' "$BODY" | jq -r .id)"
ok "test-owned process agent"
api PATCH "/issues/$ISSUE" "$(jq -nc --arg a "$AGENT" '{assigneeAgentId:$a}')" \
  || { bad "assign $IDENT to the test agent (HTTP $STATUS)"; exit 1; }

for _ in $(seq 1 90); do
  api GET "/issues/$ISSUE" && WS="$(printf '%s' "$BODY" | jq -r '.executionWorkspaceId // empty')"
  [ -n "$WS" ] && break
  sleep 1
done
[ -n "$WS" ] && ok "run realized execution workspace $WS" || { bad "execution workspace realized"; exit 1; }
for _ in $(seq 1 60); do
  api GET "/issues/$ISSUE" && [ "$(printf '%s' "$BODY" | jq -r .status)" = in_review ] && break
  sleep 1
done
[ "$(printf '%s' "$BODY" | jq -r '.status == "in_review" and .assigneeAgentId == null
    and .assigneeUserId != null and .assigneeUserId == .createdByUserId')" = true ] \
  && ok "agent key handed off: in_review, assigned to the owner (createdByUserId)" \
  || { bad "agent hand-off to in_review/owner ($(printf '%s' "$BODY" | jq -c '{status,assigneeAgentId,assigneeUserId,createdByUserId}'))"; exit 1; }
api GET "/execution-workspaces/$WS"
[ "$(printf '%s' "$BODY" | jq -r .strategyType)" = git_worktree ] \
  && ok "execution workspace is a git worktree" || bad "execution workspace is a git worktree"
WT="$(printf '%s' "$BODY" | jq -r '.cwd // empty')"
in_paperclip "test -x '$WT/.paperclip/preview'" \
  && ok "worktree carries the committed .paperclip/preview" || bad "worktree carries .paperclip/preview ($WT)"

echo "── preview up ──"
t0=$(date +%s)
if up="$(fd_paperclip preview up --issue "$IDENT")"; then
  ok "preview up --issue $IDENT ($(( $(date +%s) - t0 ))s, includes waiting out the hand-off run)"
else
  bad "preview up --issue $IDENT"; exit 1
fi
URL="$(printf '%s' "$up" | jq -r .url)"
PORT_USED="$(printf '%s' "$up" | jq -r .port)"
echo "INFO  $up"
[ "$PORT_USED" -ge "${OPC_PREVIEW_PORT_BASE:-21012}" ] && [ "$PORT_USED" -le "${OPC_PREVIEW_PORT_END:-21015}" ] \
  && ok "port $PORT_USED is in the preview slice" || bad "port $PORT_USED is in the preview slice"
page="$(curl -fsS --max-time 10 "$URL" 2>/dev/null || true)"
[[ "$page" == *"$MARKER"* ]] && ok "host fetches the marker from $URL" || bad "host fetches the marker from $URL"
page="$(curl -fsS --max-time 10 "http://127.0.0.1:$PORT_USED/" 2>/dev/null || true)"
[[ "$page" == *"$MARKER"* ]] && ok "published port serves the marker on loopback" || bad "loopback port serves the marker"
status_json="$(fd_paperclip preview status --issue "$IDENT")"
[ "$(printf '%s' "$status_json" | jq -r --argjson p "$PORT_USED" '[.[] | select(.port == $p and .status == "running")] | length')" = 1 ] \
  && ok "preview status reports it running" || bad "preview status reports it running ($status_json)"
api GET "/issues/$ISSUE"
[ "$(printf '%s' "$BODY" | jq -r '([(.labels // [])[].name] | index("preview") != null)')" = true ] \
  && ok "issue carries the preview label" || bad "issue carries the preview label"

echo "── done stops it (bridge poll ${POLL}s) ──"
api PATCH "/issues/$ISSUE" '{"status":"done"}' && ok "PATCH $IDENT done" || bad "PATCH $IDENT done (HTTP $STATUS)"
deadline=$(( $(date +%s) + 3 * POLL ))
# The bridge stops the service, then records serviceStates[<index>]="stopped"
# in a second call; wait for both, inside the same budget.
svc="" state=""
while :; do
  if api GET "/execution-workspaces/$WS"; then
    svc="$(printf '%s' "$BODY" | jq -c '[(.runtimeServices // [])[] | select(.serviceName == "preview")] | sort_by(.updatedAt // "") | last')"
    state="$(printf '%s' "$BODY" | jq -r '((.config.workspaceRuntime.services // []) | map(.name) | index("preview")) as $i
      | if $i == null then "" else (.config.serviceStates[($i | tostring)] // "") end')"
  fi
  [ "$(printf '%s' "$svc" | jq -r '.status // empty')" = stopped ] && [ "$state" = stopped ] && break
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 1
done
waited=$(( $(date +%s) - deadline + 3 * POLL ))
[ "$(printf '%s' "$svc" | jq -r '.status // empty')" = stopped ] \
  && ok "event-bridge stopped the preview (${waited}s ≤ $((3 * POLL))s)" \
  || bad "event-bridge stopped the preview within $((3 * POLL))s (service: $svc)"
[ "$state" = stopped ] \
  && ok "serviceStates records the preview stopped (restart will not revive it)" \
  || bad "serviceStates records the preview stopped (got: ${state:-none})"
api GET "/companies/$COMPANY/execution-workspaces"
[ "$(printf '%s' "$BODY" | jq --argjson p "$PORT_USED" '[.[] | (.runtimeServices // [])[]
    | select(.serviceName == "preview" and .port == $p and (.status == "running" or .status == "starting" or .status == "provisioning"))] | length')" = 0 ] \
  && ok "no live preview service holds port $PORT_USED" || bad "no live preview service holds port $PORT_USED"
if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$PORT_USED/"; then
  bad "nothing answers on $PORT_USED"
else
  ok "nothing answers on $PORT_USED"
fi
