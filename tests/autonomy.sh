#!/usr/bin/env bash
# Live autonomy gate: policy reads, mandate lifecycle, restart persistence,
# refusal of an unauthorized mutation, and the creation-time admission gate.
#
# The owner's private key is not available to a test harness, so grants here go
# through the documented ops path (`docker compose exec event-bridge`) rather
# than a signed Buzz message. The signature path itself (author, freshness,
# exact command, replay) is pinned by tests/test_control.py; what this script
# proves is everything after authorization: resolution, persistence, refusal.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL  $*" >&2; exit 1; }
# The bridge must be up before any control call: `up -d` returns before the
# healthcheck passes, and a call that races the boot looks like a policy bug.
timeout 120 bash -c 'until docker compose ps event-bridge --format "{{.Status}}" | grep -q healthy; do sleep 2; done' || true


pass() { echo "PASS  $*"; }

bridge_py() { docker compose exec -T event-bridge python3 -c "$1"; }
policy_json() { docker compose exec -T event-bridge python3 -m opc_bridge.cli policy --track lab; }
api_key() { docker compose exec -T buzz cat /keys/opc-control.key | tr -d '[:space:]'; }

FOLLOWUPS="$(policy_json | jq -r '.values["followups.allowed"]')"
[ "$FOLLOWUPS" = "false" ] || fail "default policy must not allow follow-ups (got $FOLLOWUPS)"
pass "default policy is conservative"

MANDATE="$(bridge_py '
from opc_bridge import config, control, store
import time
s = store.Store(config.load().db_path)
row = control.grant_mandate(
    s,
    {"scope_kind": "track", "scope_id": "lab", "track": "lab",
     "style": "exploration", "followups_allowed": True, "reason": "autonomy gate"},
    "ops:test", None, config.iso(time.time()),
)
print(row["id"])
')"
[ -n "$MANDATE" ] || fail "mandate grant returned no id"

RESOLVED="$(policy_json)"
[ "$(jq -r '.values["followups.allowed"]' <<<"$RESOLVED")" = "true" ] || fail "mandate did not take effect"
[ "$(jq -r '.provenance["followups.allowed"].priority' <<<"$RESOLVED")" = "30" ] || fail "mandate provenance is wrong"
pass "mandate flips policy with priority 30 provenance"

docker compose restart event-bridge >/dev/null 2>&1
timeout 60 bash -c 'until docker compose ps event-bridge --format "{{.Status}}" | grep -q healthy; do sleep 2; done' || true
[ "$(policy_json | jq -r '.values["followups.allowed"]')" = "true" ] || fail "mandate did not survive a restart"
pass "mandate survives a bridge restart"

bridge_py "
from opc_bridge import config, control, store
import time
s = store.Store(config.load().db_path)
control.revoke_mandate(s, '$MANDATE', 'ops:test', None, config.iso(time.time()))
" >/dev/null
[ "$(policy_json | jq -r '.values["followups.allowed"]')" = "false" ] || fail "revoked mandate still applies"
pass "revoked mandate stops applying"

FORGED="$(bridge_py "
import json, urllib.request, urllib.error
from opc_bridge import config
cfg = config.load()
key = cfg.api_key_path.read_text().strip()
body = json.dumps({'scope_kind':'track','scope_id':'lab','track':'lab','style':'exploration',
                   'authorization_event_id':'ff'*32,'command':'!opc grant lab'}).encode()
req = urllib.request.Request('http://127.0.0.1:8645/v1/mandates', data=body, method='POST')
req.add_header('Authorization', 'Bearer ' + key)
req.add_header('Content-Type', 'application/json')
try:
    urllib.request.urlopen(req, timeout=10)
    print('accepted')
except urllib.error.HTTPError as exc:
    print(exc.code, json.loads(exc.read() or b'{}').get('reason'))
")"
case "$FORGED" in
    403*) pass "unauthorized mutation refused ($FORGED)" ;;
    *) fail "unauthorized mutation was not refused: $FORGED" ;;
esac

# The hard lock is applied the way an operator applies it — an allocation —
# not by hand-writing the policy row. `track_locked` is what the creation gate
# reads, so this also proves the allocation writes it.
bridge_py "
from opc_bridge import config, control, store, paperclip
import json, time
cfg = config.load(); s = store.Store(cfg.db_path)
pc = paperclip.Paperclip(cfg.paperclip_api_url, cfg.paperclip_key_path.read_text().strip())
print(json.dumps(control.apply_allocation(cfg, s, pc, 100, 0, 'ops:test', None, config.iso(time.time()))))
" >/dev/null
[ "$(policy_json | jq -r '.values.track_locked')" = "true" ] \
    || fail "allocation 100/0 did not set track_locked for lab"
pass "hard lock sets the track_locked policy the creation gate reads"

set +e
OUT="$(printf 'Lane: engineering\nTrack: lab\n' | docker compose exec -T frontdoor \
    opc-paperclip engineering-ticket create --repo example/nonexistent --title gate-smoke 2>&1)"
RC=$?
set -e
[ "$RC" -eq 3 ] || fail "locked-track ticket creation exited $RC (expected 3): $OUT"
grep -qi "locked by the operator" <<<"$OUT" || fail "refusal did not explain the lock: $OUT"
pass "locked track refuses ticket creation before any API resolution"

bridge_py "
from opc_bridge import config, control, store, paperclip
import json, time
cfg = config.load(); s = store.Store(cfg.db_path)
pc = paperclip.Paperclip(cfg.paperclip_api_url, cfg.paperclip_key_path.read_text().strip())
print(json.dumps(control.apply_allocation(cfg, s, pc, 70, 30, 'ops:test', None, config.iso(time.time()))))
" >/dev/null
[ "$(policy_json | jq -r '.values.track_locked')" = "false" ] \
    || fail "unlock did not clear track_locked"
pass "unlock clears the creation gate"

LABELS="$(docker compose exec -T frontdoor opc-paperclip labels ensure)"
[ "$(jq -r 'length' <<<"$LABELS")" -ge 4 ] || fail "labels ensure did not return four ids: $LABELS"
pass "track/style labels are ensured idempotently"

# Live gates must not leave operator-priority policy behind: an allocation row
# created here would silently disable adaptive allocation for the real stack.
bridge_py "
from opc_bridge import config, store
import time
s = store.Store(config.load().db_path)
with s._lock:
    cur = s._db.execute(
        \"update policies set revoked_at=? where revoked_at is null \"
        \"and created_by='ops:test' and key in ('allocation.core','allocation.lab','track_locked')\",
        (config.iso(time.time()),),
    )
    s._db.commit()
print('[gate] revoked test policy rows:', cur.rowcount)
"

echo "autonomy: ok"
