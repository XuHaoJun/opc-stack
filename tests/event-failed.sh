#!/usr/bin/env bash
# Live gate for `paperclip.issue.failed` (requirement §3.5/§3.7).
#
# A throwaway `process`-adapter agent runs a command that exits 1 on a real
# ticket. The bridge must emit exactly one failed event for that run even though
# the ticket's own row never changes — that is what the company-wide run sweep
# exists for. The agent and ticket are cleaned up afterwards, and the one
# notification is deleted.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL  $*" >&2; exit 1; }
pass() { echo "PASS  $*"; }
skip() { echo "SKIP  $*"; }

timeout 120 bash -c 'until docker compose ps event-bridge --format "{{.Status}}" | grep -q healthy; do sleep 2; done' || true

BOARD_KEY="$(docker compose exec -T paperclip cat /paperclip/.opc/board-api.key | tr -d '[:space:]')"
PCAPI="http://127.0.0.1:3100/api"
pc_get() { docker compose exec -T paperclip curl -fsS -H "Authorization: Bearer $BOARD_KEY" "$PCAPI$1"; }
pc_post() { docker compose exec -T paperclip curl -fsS -X POST -H "Authorization: Bearer $BOARD_KEY" -H "Content-Type: application/json" -d "$2" "$PCAPI$1"; }
pc_patch() { docker compose exec -T paperclip curl -fsS -X PATCH -H "Authorization: Bearer $BOARD_KEY" -H "Content-Type: application/json" -d "$2" "$PCAPI$1"; }
pc_delete() { docker compose exec -T paperclip curl -fsS -X DELETE -H "Authorization: Bearer $BOARD_KEY" "$PCAPI$1"; }

COMPANY="$(pc_get /companies | jq -r '.[0].id')"
[ -n "$COMPANY" ] || fail "no company visible to the board key"
STAMP="$(date +%s)"
# One reusable agent. It is paused between runs (not terminated): DELETE fails
# upstream once an agent has run history (`purgeAgent` errors deleting
# heartbeat_runs), and terminating it would make it unusable for the next run.
AGENT_NAME="event-failed-smoke"
AGENT_ID=""
ISSUE_ID=""

cleanup() {
    [ -n "$ISSUE_ID" ] && pc_patch "/issues/$ISSUE_ID" '{"status":"backlog"}' >/dev/null 2>&1 || true
    [ -n "$AGENT_ID" ] && pc_patch "/agents/$AGENT_ID" '{"status":"paused"}' >/dev/null 2>&1 || true
}
trap cleanup EXIT

AGENT_ID="$(pc_get "/companies/$COMPANY/agents" | jq -r --arg n "$AGENT_NAME" '[.[] | select(.name == $n)][0].id // empty')"
if [ -z "$AGENT_ID" ]; then
    BODY="$(jq -nc --arg name "$AGENT_NAME" '{
        name:$name, adapterType:"process",
        adapterConfig:{command:"sh", args:["-c","echo intentional failure >&2; exit 1"]},
        runtimeConfig:{heartbeat:{enabled:false, maxConcurrentRuns:1}}
    }')"
    AGENT_ID="$(pc_post "/companies/$COMPANY/agents" "$BODY" | jq -r '.id // empty')"
    [ -n "$AGENT_ID" ] || fail "could not create the reusable test agent"
else
    # Resume it for this run; it was paused by the previous one.
    pc_patch "/agents/$AGENT_ID" '{"status":"idle"}' >/dev/null 2>&1 || true
fi

for _ in $(seq 1 30); do
    STATUS="$(pc_get "/agents/$AGENT_ID" | jq -r '.status // empty')"
    case "$STATUS" in idle|active|running) break ;; esac
    sleep 1
done
[ "$STATUS" = "idle" ] || [ "$STATUS" = "active" ] \
    || fail "throwaway agent is not invokable (status=$STATUS; harness verification may have paused it)"
pass "throwaway process agent is invokable"

TICKET="$(jq -nc --arg a "$AGENT_ID" --arg t "event-failed smoke $STAMP" \
    '{title:$t, description:"Synthetic failing run for tests/event-failed.sh", status:"todo", assigneeAgentId:$a}')"
ISSUE_ID="$(pc_post "/companies/$COMPANY/issues" "$TICKET" | jq -r '.id // empty')"
[ -n "$ISSUE_ID" ] || fail "could not create the test ticket"

RUN_ID=""
for _ in $(seq 1 40); do
    RUN_ID="$(pc_get "/issues/$ISSUE_ID/runs" | jq -r --argjson skip 0 '
        if type == "array" then . else (.runs // []) end
        | [.[] | select(.status == "failed" or .status == "timed_out")]
        | [.[] | .runId // .id][0] // empty')"
    [ -n "$RUN_ID" ] && break
    sleep 2
done
[ -n "$RUN_ID" ] || fail "no failed run appeared for the test ticket within 80s"
pass "the test run failed (run $RUN_ID)"

FOUND=""
for _ in $(seq 1 45); do
    FOUND="$(docker compose exec -T event-bridge python3 -c "
from opc_bridge import config
import json, urllib.request
cfg = config.load()
key = cfg.api_key_path.read_text().strip()
req = urllib.request.Request('http://127.0.0.1:8645/v1/events?limit=100')
req.add_header('Authorization', 'Bearer ' + key)
with urllib.request.urlopen(req, timeout=10) as resp:
    rows = json.load(resp).get('events', [])
print(sum(1 for r in rows if r.get('event_type') == 'paperclip.issue.failed' and r.get('run_id') == '$RUN_ID'))
")"
    [ "${FOUND:-0}" -ge 1 ] && break
    sleep 2
done
[ "${FOUND:-0}" -ge 1 ] || fail "the bridge did not emit paperclip.issue.failed for run $RUN_ID"
pass "paperclip.issue.failed emitted for the run without the ticket row changing"

# The notification lands in the control channel (the ticket has no Buzz markers).
CTL="$(docker compose exec -T event-bridge python3 -c "from opc_bridge import config, store; print(store.Store(config.load().db_path).get_meta('control_channel') or '')")"
if [ -n "$CTL" ]; then
    docker compose exec -T frontdoor sh -c '
R=$(printf "%s" "$BUZZ_RELAY_URL" | sed "s#^wss\\?://##")
BUZZ_AUTH_TAG= buzz --relay "http://$R" --private-key "$(cat /keys/paperclip.nsec)" messages get --channel '"$CTL"' --limit 100 \
  | jq -r ".[] | select(.content|contains(\"'"$RUN_ID"'\")) | .id" ' 2>/dev/null \
    | while read -r id; do
        [ -n "$id" ] || continue
        docker compose exec -T frontdoor sh -c '
R=$(printf "%s" "$BUZZ_RELAY_URL" | sed "s#^wss\\?://##")
BUZZ_AUTH_TAG= buzz --relay "http://$R" --private-key "$(cat /keys/paperclip.nsec)" messages delete --event '"$id"'' >/dev/null 2>&1 || true
      done
fi
pass "test notification cleaned up"

echo "event-failed: ok ($RUN_ID)"
