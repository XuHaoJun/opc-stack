#!/usr/bin/env bash
# Live admission gate: a zero-share track stops at Paperclip itself.
#
# The lock is applied through the documented ops path (exec into the bridge) —
# the owner-signature path is pinned by unit tests. What this proves is the
# effect: only the locked track's agents are paused, a ticket filed at that
# track never reaches a running execution, the lock survives restarts, and an
# adaptive decision cannot undo an operator lock.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL  $*" >&2; exit 1; }
# The bridge must be up before any control call: `up -d` returns before the
# healthcheck passes, and a call that races the boot looks like a policy bug.
timeout 120 bash -c 'until docker compose ps event-bridge --format "{{.Status}}" | grep -q healthy; do sleep 2; done' || true


pass() { echo "PASS  $*"; }

bridge_py() { docker compose exec -T event-bridge python3 -c "$1"; }
BOARD_KEY="$(docker compose exec -T paperclip cat /paperclip/.opc/board-api.key | tr -d '[:space:]')"
PCAPI="http://127.0.0.1:3100/api"
pc_get() { docker compose exec -T paperclip curl -fsS -H "Authorization: Bearer $BOARD_KEY" "$PCAPI$1"; }
pc_post() { docker compose exec -T paperclip curl -fsS -X POST -H "Authorization: Bearer $BOARD_KEY" -H "Content-Type: application/json" -d "$2" "$PCAPI$1"; }

COMPANY="$(pc_get /companies | jq -r '.[0].id')"
agent_status() { pc_get "/companies/$COMPANY/agents" | jq -r --arg n "$1" '.[] | select(.name == $n) | .status'; }
PROTO_ID="$(pc_get "/companies/$COMPANY/agents" | jq -r '.[] | select(.name == "Prototyper") | .id')"
SCI_ID="$(pc_get "/companies/$COMPANY/agents" | jq -r '.[] | select(.name == "Scientist") | .id')"
ENG_ID="$(pc_get "/companies/$COMPANY/agents" | jq -r '.[] | select(.role == "engineer") | .id')"
[ -n "$PROTO_ID" ] && [ -n "$SCI_ID" ] && [ -n "$ENG_ID" ] || fail "lane agents not found"

apply() { # <core> <lab> [adaptive]
    bridge_py "
from opc_bridge import config, control, store, paperclip
import json, time
cfg = config.load()
s = store.Store(cfg.db_path)
pc = paperclip.Paperclip(cfg.paperclip_api_url, cfg.paperclip_key_path.read_text().strip())
print(json.dumps(control.apply_allocation(cfg, s, pc, $1, $2, 'ops:test', None, config.iso(time.time()), adaptive=${3:-False})))
"
}

OUT="$(apply 100 0)"
grep -q '"applied": true' <<<"$OUT" || fail "lock was not applied: $OUT"
[ "$(agent_status Prototyper)" = "paused" ] || fail "Prototyper is not paused"
[ "$(agent_status Scientist)" = "paused" ] || fail "Scientist is not paused"
[ "$(agent_status 'Fullstack Engineer')" != "paused" ] || fail "core agent was paused by a lab lock"
pass "Lab 0% pauses only the lab agents"

BODY="$(jq -nc --arg a "$PROTO_ID" '{title:"admission gate", description:"Lab 0% smoke", status:"todo", assigneeAgentId:$a}')"
ISSUE="$(pc_post "/companies/$COMPANY/issues" "$BODY" | jq -r '.id')"
sleep 25
RUNNING="$(pc_get "/issues/$ISSUE/live-runs" | jq -r '[ (.runs // .)[] | select(.status == "running") ] | length' 2>/dev/null || echo 0)"
[ "$RUNNING" = "0" ] || fail "a run started on a locked track ($RUNNING running)"
STATUS="$(pc_get "/issues/$ISSUE" | jq -r '.status')"
[ "$STATUS" != "in_progress" ] || fail "locked ticket moved to in_progress"
pass "ticket on the locked track never reached a running execution (status=$STATUS)"

docker compose restart event-bridge >/dev/null 2>&1
timeout 60 bash -c 'until docker compose ps event-bridge --format "{{.Status}}" | grep -q healthy; do sleep 2; done' || true
[ "$(agent_status Prototyper)" = "paused" ] || fail "lock did not survive a bridge restart"
pass "lock survives a bridge restart"

OUT="$(apply 90 10 True)"
grep -q '"applied": false' <<<"$OUT" || fail "adaptive decision overrode the operator lock: $OUT"
[ "$(agent_status Prototyper)" = "paused" ] || fail "adaptive decision resumed a locked agent"
pass "adaptive allocation cannot override an operator lock"

apply 70 30 >/dev/null
for _ in $(seq 1 20); do
    [ "$(agent_status Prototyper)" != "paused" ] && break
    sleep 2
done
[ "$(agent_status Prototyper)" != "paused" ] || fail "lab agents did not resume at 70/30"
pass "70/30 resumes the lab agents"

echo "admission: ok ($ISSUE)"
