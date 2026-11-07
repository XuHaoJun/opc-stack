#!/usr/bin/env bash
# Phase 1 exit gate: the live event loop.
#
# Creates real Paperclip issues (no agent run: assigned to a paused agent and
# parked in backlog), adds the markers the front door writes, flips them to
# done, and asserts that the bridge delivered exactly one signed message into
# the origin thread — as the `paperclip` identity, anchored to the trigger, with
# the machine tag a consumer dedupes on.
#
# Also proves: a ticket that completes while the bridge is stopped is delivered
# once on restart, and a tagged event from an unlisted author is dropped by the
# buzz-acp gate instead of becoming a turn.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL  $*" >&2; exit 1; }
# The bridge must be up before any control call: `up -d` returns before the
# healthcheck passes, and a call that races the boot looks like a policy bug.
timeout 120 bash -c 'until docker compose ps event-bridge --format "{{.Status}}" | grep -q healthy; do sleep 2; done' || true


pass() { echo "PASS  $*"; }
note() { echo "SKIP  $*"; }

RELAY="$(docker compose exec -T frontdoor printenv BUZZ_RELAY_URL | tr -d '[:space:]')"
RELAY_HTTP="http://$(printf '%s' "$RELAY" | sed 's#^wss\?://##')"
CHANNEL="$(docker compose exec -T frontdoor sh -c "BUZZ_AUTH_TAG= buzz --relay $RELAY_HTTP --private-key \"\$(cat /keys/paperclip.nsec)\" channels list" \
    | jq -r '[.[] | select(.name == "prototypes")][0].channel_id // .[0].channel_id')"
[ -n "$CHANNEL" ] || fail "no channel available to receive the notice"

PAPERCLIP_PUB="$(docker compose exec -T buzz cat /keys/paperclip.pub | tr -d '[:space:]')"
BOARD_KEY="$(docker compose exec -T paperclip cat /paperclip/.opc/board-api.key | tr -d '[:space:]')"
PCAPI="http://127.0.0.1:3100/api"

pc_get() {
    docker compose exec -T paperclip curl -fsS -H "Authorization: Bearer $BOARD_KEY" "$PCAPI$1"
}
pc_post() {
    docker compose exec -T paperclip curl -fsS -X POST -H "Authorization: Bearer $BOARD_KEY" \
        -H "Content-Type: application/json" -d "$2" "$PCAPI$1"
}
pc_patch() {
    docker compose exec -T paperclip curl -fsS -X PATCH -H "Authorization: Bearer $BOARD_KEY" \
        -H "Content-Type: application/json" -d "$2" "$PCAPI$1"
}
messages() {
    docker compose exec -T frontdoor sh -c "BUZZ_AUTH_TAG= buzz --relay $RELAY_HTTP --private-key \"\$(cat /keys/paperclip.nsec)\" messages get --channel $CHANNEL --limit 80" \
        2>/dev/null || echo '[]'
}
anchor() {
    messages | jq -r 'sort_by(.created_at) | last | .id // empty'
}
count_for_issue() { # <identifier>
    messages | jq --arg ident "$1" '[.[] | select((.tags // []) | any(.[0] == "opc-issue" and .[1] == $ident))] | length'
}
wait_for_message() { # <identifier> <timeout-seconds>
    local ident="$1" deadline=$(( $(date +%s) + ${2:-60} ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        [ "$(count_for_issue "$ident")" -ge 1 ] && return 0
        sleep 3
    done
    return 1
}

COMPANY="$(pc_get /companies | jq -r '.[0].id')"
[ -n "$COMPANY" ] || fail "no company visible to the board key"
AGENT="$(pc_get "/companies/$COMPANY/agents" | jq -r '[.[] | select(.status == "paused")][0].id // empty')"
HOLDER_AGENT=""
if [ -z "$AGENT" ]; then
    # A fresh install has no paused agent, and an idle one is woken by the
    # assignment (issue-assignment-wakeup keys off status, not heartbeat), so the
    # holder must be a real paused agent. Create a throwaway one and remove it on
    # exit — the tickets above/below exist only to exercise delivery.
    HOLDER_AGENT="$(pc_post "/companies/$COMPANY/agents" \
        "$(jq -nc --arg n "opc-event-loop-holder-$$" \
            '{name:$n, role:"general", adapterType:"process", runner:"legacy", adapterConfig:{}}')" \
        | jq -r '.id // empty')"
    [ -n "$HOLDER_AGENT" ] || fail "no paused agent and the throwaway holder could not be created"
    pc_patch "/agents/$HOLDER_AGENT" '{"status":"paused"}' >/dev/null || fail "could not pause the throwaway holder"
    AGENT="$HOLDER_AGENT"
fi
# v2026.1023.0+ requires terminate before DELETE; an agent that never ran has no
# cost_events, so this delete is clean.
delete_holder() {
    [ -n "$HOLDER_AGENT" ] || return 0
    pc_post "/agents/$HOLDER_AGENT/terminate" '{}' >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        _st="$(pc_get "/agents/$HOLDER_AGENT" 2>/dev/null | jq -r '.lifecycleState // empty' 2>/dev/null)"
        [ "$_st" = "terminated" ] && break
        sleep 1
    done
    docker compose exec -T paperclip curl -fsS -X DELETE \
        -H "Authorization: Bearer $BOARD_KEY" "$PCAPI/agents/$HOLDER_AGENT" >/dev/null 2>&1 || true
}

ensure_anchor() {
    local a
    a="$(anchor)"
    if [ -z "$a" ]; then
        # A fresh stack's channel can be empty, but the ticket comments need an
        # existing Buzz event to point at. Publish one neutral message as the
        # paperclip identity (it is not a driveable agent, so nothing wakes) and
        # use it as this run's thread anchor.
        docker compose exec -T frontdoor sh -c "BUZZ_AUTH_TAG= buzz --relay $RELAY_HTTP --private-key \"\$(cat /keys/paperclip.nsec)\" messages send --channel $CHANNEL --content 'event-loop anchor (test bootstrap)'" >/dev/null 2>&1 || true
        for _ in $(seq 1 15); do
            a="$(anchor)"
            [ -n "$a" ] && break
            sleep 2
        done
    fi
    printf '%s' "$a"
}

create_ticket() { # <identifier-suffix> → prints "<id> <anchor>"
    local title="OPC event-loop smoke $1" anchor_id body id ident
    anchor_id="$(ensure_anchor)"
    [ -n "$anchor_id" ] || fail "could not read a Buzz event id to use as the thread anchor"
    body="$(jq -nc --arg t "$title" --arg a "$AGENT" \
        '{title:$t, description:"Synthetic ticket for tests/event-loop.sh; no agent run.", status:"backlog", assigneeAgentId:$a}')"
    id="$(pc_post "/companies/$COMPANY/issues" "$body" | jq -r '.id')"
    [ -n "$id" ] || fail "issue creation returned no id"
    ident="$(pc_get "/issues/$id" | jq -r '.identifier')"
    pc_post "/issues/$id/comments" "$(jq -nc --arg c "$CHANNEL" '{body:("BUZZ_CHANNEL: " + $c)}')" >/dev/null
    pc_post "/issues/$id/comments" "$(jq -nc --arg e "$anchor_id" '{body:("BUZZ_EVENT: " + $e)}')" >/dev/null
    echo "$id $ident $anchor_id"
}

# ── C. forged tagged event is dropped by the wake gate ──
# Runs FIRST, while the agent queue is idle: the gate decision happens when the
# event is dequeued, so a probe queued behind two real Hermes turns is only
# logged minutes later.───────────────
# The probe is sent with a THROWAWAY identity and deleted afterwards: the wake
# gate only decides whether a turn happens, it does not stop the relay from
# storing the message, so a real identity would leave test noise in the channel
# (and it did: repeated runs left "forged opc event" messages authored by the
# scientist).
BEFORE="$(docker compose logs frontdoor 2>&1 | grep -c "opc event gate — dropping event" || true)"

FORGE_EVENT="$(docker compose exec -T frontdoor sh -c '
set -eu
R=$(printf "%s" "$BUZZ_RELAY_URL" | sed "s#^wss\?://##")
OUT=$(buzz-admin generate-key)
SEC=$(printf "%s" "$OUT" | sed -n "s/^Secret key:  //p")
printf "%s" "$SEC" > /tmp/opc-forge.nsec
BUZZ_AUTH_TAG= buzz --relay "http://$R" --private-key "$SEC" messages send \
    --channel '"$CHANNEL"' --content "forged opc event (test probe)" --tag opc-event=evt_forged
' | jq -r '.event_id')"
[ -n "$FORGE_EVENT" ] || fail "could not publish the forgery probe"

delete_forge() {
    docker compose exec -T frontdoor sh -c '
R=$(printf "%s" "$BUZZ_RELAY_URL" | sed "s#^wss\?://##")
[ -f /tmp/opc-forge.nsec ] || exit 0
BUZZ_AUTH_TAG= buzz --relay "http://$R" --private-key "$(cat /tmp/opc-forge.nsec)" \
    messages delete --event '"$FORGE_EVENT"' >/dev/null 2>&1 || echo "WARN  forgery probe not deleted"
rm -f /tmp/opc-forge.nsec
' >/dev/null 2>&1 || true
}
trap 'delete_forge; delete_holder' EXIT

DROPPED=0
for _ in $(seq 1 10); do
    AFTER="$(docker compose logs frontdoor 2>&1 | grep -c "opc event gate — dropping event" || true)"
    [ "${AFTER:-0}" -gt "${BEFORE:-0}" ] && { DROPPED=1; break; }
    sleep 2
done
[ "$DROPPED" -eq 1 ] || fail "a tagged event from an unlisted author was not dropped by the wake gate"
pass "forged tagged event dropped by the wake gate (no turn)"

delete_forge
trap delete_holder EXIT
LEFT="$(messages | jq --arg id "$FORGE_EVENT" '[.[] | select(.id == $id)] | length')"
[ "${LEFT:-0}" = "0" ] || fail "the forgery probe is still visible in the channel ($FORGE_EVENT)"
pass "forgery probe removed from the channel"

# ── A. completion event ──────────────────────────────────────────────────
read -r ISSUE_ID IDENT ANCHOR_ID <<<"$(create_ticket happy)"
pc_patch "/issues/$ISSUE_ID" '{"status":"done"}' >/dev/null
wait_for_message "$IDENT" 90 || fail "no event delivered for $IDENT within 90s"
[ "$(count_for_issue "$IDENT")" -eq 1 ] || fail "expected exactly one message for $IDENT, got $(count_for_issue "$IDENT")"

ROW="$(messages | jq --arg ident "$IDENT" -c '[.[] | select((.tags // []) | any(.[0] == "opc-issue" and .[1] == $ident))][0]')"
[ "$(jq -r '.pubkey' <<<"$ROW")" = "$PAPERCLIP_PUB" ] || fail "notice is not authored by the paperclip identity"
jq -e '(.tags // []) | any(.[0] == "opc-event-type" and .[1] == "paperclip.issue.completed")' <<<"$ROW" >/dev/null \
    || fail "notice lacks opc-event-type=paperclip.issue.completed"
jq -e '(.tags // []) | any(.[0] == "e" and .[1] == "'"$ANCHOR_ID"'")' <<<"$ROW" >/dev/null \
    || fail "notice is not a reply to the trigger event ($ANCHOR_ID)"
jq -e --arg id "$(jq -r '(.tags // []) | map(select(.[0]=="opc-event"))[0][1] // ""' <<<"$ROW")" \
    '.content | endswith("OPC_EVENT: " + $id)' <<<"$ROW" >/dev/null \
    || fail "machine line OPC_EVENT is missing or does not match the tag"
pass "completion event delivered once, by paperclip, into the origin thread"

# ── B. crash recovery ────────────────────────────────────────────────────
read -r ISSUE2_ID IDENT2 _ <<<"$(create_ticket recovery)"
docker compose stop event-bridge >/dev/null 2>&1
pc_patch "/issues/$ISSUE2_ID" '{"status":"done"}' >/dev/null
sleep 8
[ "$(count_for_issue "$IDENT2")" -eq 0 ] || fail "$IDENT2 was delivered while the bridge was stopped"
docker compose start event-bridge >/dev/null 2>&1
wait_for_message "$IDENT2" 90 || fail "no event delivered for $IDENT2 after restart"
[ "$(count_for_issue "$IDENT2")" -eq 1 ] || fail "expected exactly one message for $IDENT2 after restart, got $(count_for_issue "$IDENT2")"
pass "ticket completed while the bridge was down delivered once on restart"

note "duplicate-turn suppression is enforced by the same gate and covered by tests/buzz-event-gate.sh + unit tests"
echo "event-loop: ok ($IDENT, $IDENT2)"
