#!/usr/bin/env bash
# Offline regression gate for the ticket-creation payloads.
#
# The helper builds JSON with `jq`; a malformed program is invisible until
# someone files a ticket, where it surfaces as a jq compile error (a real
# incident: the prototype payload was missing a closing brace). The builders
# are functions and the script supports OPC_PAPERCLIP_SOURCE_ONLY, so this test
# validates the exact JSON without touching Paperclip or the board.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL  $*" >&2; exit 1; }
pass() { echo "PASS  $*"; }

export OPC_PAPERCLIP_SOURCE_ONLY=1
# shellcheck disable=SC1091
. patches/buzz/opc-paperclip

DESC="$(mktemp)"
trap 'rm -f "$DESC"' EXIT
printf 'Prototype: demo\nScope: x\nAcceptance: y\n' >"$DESC"

# ── prototype ────────────────────────────────────────────────────────────
PROTO="$(prototype_payload_json "$DESC" "Title" "" "agent-1" "" "" "" "Prototype: demo" 1 false '["l1","l2"]')" \
    || fail "prototype_payload_json failed to build a payload"
jq -e . <<<"$PROTO" >/dev/null || fail "prototype payload is not valid JSON: $PROTO"
jq -e '.labelIds == ["l1","l2"]' <<<"$PROTO" >/dev/null \
    || fail "prototype payload lost its labelIds"
jq -e '.title == "Prototype: demo" and .assigneeAgentId == "agent-1"' <<<"$PROTO" >/dev/null \
    || fail "prototype payload has the wrong title/assignee"
jq -e 'has("projectId") | not' <<<"$PROTO" >/dev/null \
    || fail "prototype payload invented a projectId from an empty value"
jq -e 'has("priority") | not' <<<"$PROTO" >/dev/null \
    || fail "prototype payload invented a priority from an empty value"
pass "prototype payload builds valid JSON with labels"

# ── engineering ──────────────────────────────────────────────────────────
ENG="$(engineering_payload_json "$DESC" "E" "" "" "inherit" "" "agent-2" "proj-1" "ws-1" '{"mode":"inherit"}' '[]')" \
    || fail "engineering_payload_json failed to build a payload"
jq -e . <<<"$ENG" >/dev/null || fail "engineering payload is not valid JSON: $ENG"
jq -e '.projectId == "proj-1" and .projectWorkspaceId == "ws-1"' <<<"$ENG" >/dev/null \
    || fail "engineering payload lost its project binding"
jq -e '.executionWorkspacePreference == "inherit" and .labelIds == []' <<<"$ENG" >/dev/null \
    || fail "engineering payload lost its mode/labels"
jq -e 'has("status") | not' <<<"$ENG" >/dev/null \
    || fail "engineering payload invented a status from an empty value"
pass "engineering payload builds valid JSON with project binding"

# ── the retired watcher must not be reachable from the helper's docs ─────
if grep -q "opc-issue-watcher" patches/buzz/opc-paperclip patches/buzz/skills patches/hermes/skills 2>/dev/null; then
    fail "a shipped skill still references the retired watcher binary"
fi
pass "no shipped skill names the retired watcher"

echo "opc-paperclip: ok"
