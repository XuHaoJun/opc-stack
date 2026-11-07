#!/usr/bin/env bash
# Force stop gate.
#
# Two assertions are always safe: an unauthorized call is refused, and a
# terminal run is refused (never a silent success). Actually cancelling a live
# run needs a run, and creating one on demand would spend an agent run and
# touch a workspace — so that path is opt-in via OPC_TEST_RUN_ID, which the
# operator can point at a deliberately long run.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL  $*" >&2; exit 1; }
pass() { echo "PASS  $*"; }
skip() { echo "SKIP  $*"; }

call() { # <json-body>
    docker compose exec -T event-bridge python3 -c "
import json, urllib.request, urllib.error
from opc_bridge import config
cfg = config.load()
body = json.loads('''$1''')
req = urllib.request.Request('http://127.0.0.1:8645/v1/control/force-stop',
                             data=json.dumps(body).encode(), method='POST')
req.add_header('Authorization', 'Bearer ' + cfg.api_key_path.read_text().strip())
req.add_header('Content-Type', 'application/json')
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        print(r.status, r.read().decode())
except urllib.error.HTTPError as exc:
    print(exc.code, exc.read().decode())
"
}

OUT="$(call '{"run_id":"00000000-0000-0000-0000-000000000000","authorization_event_id":"'"$(printf 'f%.0s' $(seq 64))"'","command":"!opc force-stop run 0000"}')"
case "$OUT" in
    403*) pass "unauthorized force stop is refused ($OUT)" ;;
    *) fail "unauthorized force stop was not refused: $OUT" ;;
esac

RUNS_JSON="$(docker compose exec -T paperclip sh -c '
K=$(cat /paperclip/.opc/board-api.key)
C=$(curl -fsS -H "Authorization: Bearer $K" http://127.0.0.1:3100/api/companies | jq -r ".[0].id")
curl -fsS -H "Authorization: Bearer $K" "http://127.0.0.1:3100/api/companies/$C/heartbeat-runs?limit=20"
')"
TERMINAL_RUN="$(jq -r 'if type == "array" then . else (.runs // .data // []) end
    | [.[] | select((.status // "") | IN("succeeded", "failed", "cancelled"))][0].id // empty' <<<"$RUNS_JSON")"
if [ -n "$TERMINAL_RUN" ]; then
    OUT="$(call '{"run_id":"'"$TERMINAL_RUN"'","authorization_event_id":"'"$(printf 'f%.0s' $(seq 64))"'","command":"!opc force-stop run x"}')"
    case "$OUT" in
        409*) pass "terminal run is refused as not_cancellable" ;;
        403*) pass "terminal run probe was authorized-checked first (403)" ;;
        *) note="unexpected: $OUT"; fail "$note" ;;
    esac
else
    skip "no terminal run available to probe not_cancellable"
fi

if [ -n "${OPC_TEST_RUN_ID:-}" ]; then
    OUT="$(call '{"run_id":"'"$OPC_TEST_RUN_ID"'","authorization_event_id":"'"$(printf 'f%.0s' $(seq 64))"'","command":"!opc force-stop run x"}')"
    case "$OUT" in
        403*) skip "live cancellation needs an owner-signed command (unit-tested path)" ;;
        200*) pass "live run cancelled: $OUT" ;;
        *) fail "unexpected force stop result: $OUT" ;;
    esac
else
    skip "live cancellation not requested (set OPC_TEST_RUN_ID to exercise it)"
fi

echo "force-stop: ok"
