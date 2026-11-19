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

# Drive the dispatcher command through its real parsing and mutation logic.
feedback_id=$(printf '%064d' 1)
root_id=$(printf '%064d' 2)
notice_id=$(printf '%064d' 3)
owner=$(printf '%064d' 4)
notifier=$(printf '%064d' 5)
agent=$(printf '%064d' 6)
other=$(printf '%064d' 7)
channel=10000000-0000-4000-8000-000000000000
issue_id=20000000-0000-4000-8000-000000000000
scratch=$(mktemp -d)
printf '%s' "$notifier" >"$scratch/paperclip.pub"
printf '%s' "$agent" >"$scratch/agent.pub"
printf '%s' "$other" >"$scratch/relay.pub"
trap 'rm -f "$DESC" "$scratch/paperclip.pub" "$scratch/agent.pub" "$scratch/relay.pub" "$scratch/write"; rmdir "$scratch"' EXIT
export BUZZ_KEYS_DIR="$scratch" BUZZ_ACP_AGENT_OWNER="$owner" PAPERCLIP_PUBLIC_URL=https://board.example
fixture=$(jq -nc --arg f "$feedback_id" --arg r "$root_id" --arg n "$notice_id" \
    --arg o "$owner" --arg p "$notifier" --arg c "$channel" '
    [{id:$r,pubkey:$o,kind:9,tags:[["h",$c]],content:"QA request"},
     {id:$n,pubkey:$p,kind:9,tags:[["h",$c],["opc-event","evt_123"],["opc-issue","OPC-3"]],reply_to:$r},
     {id:$f,pubkey:$o,kind:9,tags:[["h",$c]],reply_to:$n,thread_root:$r,content:"Volume at zero still plays"}]')
buzz() { printf '%s\n' "$fixture"; }
company_id() { printf 'test-company\n'; }
api_request() {
    case "$*" in
        "GET /issues/OPC-3"|"GET /issues/$issue_id")
            if [[ "$*" == "GET /issues/$issue_id" && -f "$scratch/write" ]]; then now=todo; else now=${issue_status:-in_review}; fi
            jq -nc --arg id "$issue_id" --arg status "$now" \
                --arg company "${issue_company:-test-company}" \
                '{id:$id,identifier:"OPC-3",companyId:$company,projectId:"project-1",assigneeAgentId:"engineer-1",status:$status,title:"Volume control"}' ;;
        "GET /issues/OPC-4")
            printf '%s\n' '{"id":"30000000-0000-4000-8000-000000000000","identifier":"OPC-4","companyId":"test-company","projectId":"project-2","status":"in_review"}' ;;
        "GET /issues/$issue_id/comments")
            jq -nc --arg c "$channel" --arg id "${persisted_root:-$root_id}" \
                '[{authorUserId:"board-user",body:("BUZZ_CHANNEL: "+$c+"\nBUZZ_EVENT: "+$id)}]' ;;
        "GET /issues/$issue_id/work-products") printf '%s\n' "${work_products:-[]}" ;;
        "PATCH /issues/$issue_id "*|"POST /issues/$issue_id/comments "*)
            printf '%s\n' "$3" >"$scratch/write"
            if [ "$1" = PATCH ]; then
                jq -nc --arg id "$issue_id" '{id:$id,status:"todo"}'
            else
                printf '%s\n' '{"id":"comment-1"}'
            fi ;;
        *) return 1 ;;
    esac
}
lookup="$(main buzz-feedback resolve --channel "$channel" --event "$feedback_id")"
jq -e '.decision == "linked" and .issues[0].identifier == "OPC-3"' <<<"$lookup" >/dev/null ||
    fail "signed Paperclip notification did not resolve original ticket"
main buzz-feedback continue --channel "$channel" --event "$feedback_id" --issue OPC-3 >/dev/null
jq -e '.status == "todo" and (.comment | contains("Volume at zero still plays"))' "$scratch/write" >/dev/null ||
    fail "active QA rejection did not return the same issue to the engineer"
pass "confirmed Buzz feedback returns the same in-review issue"

saved="$fixture"
fixture=$(jq --arg agent "$agent" '.[] |= if .id == "'$notice_id'" then
    .pubkey=$agent | .tags=[.tags[0]] | .content="Ticket: https://board.example/issues/OPC-3"
    else . end' <<<"$saved")
lookup="$(main buzz-feedback resolve --channel "$channel" --event "$feedback_id")"
jq -e '.decision == "linked" and .issues[0].identifier == "OPC-3"' <<<"$lookup" >/dev/null ||
    fail "first QA handoff before a Paperclip terminal event did not resolve"
pass "frontdoor ticket link must match the persisted Buzz origin"

persisted_root="$other"
lookup="$(main buzz-feedback resolve --channel "$channel" --event "$feedback_id")"
jq -e '.decision == "unlinked"' <<<"$lookup" >/dev/null ||
    fail "frontdoor mention linked an issue from a different thread"
unset persisted_root

fixture=$(jq --arg c "$channel" --arg p "$notifier" --arg r "$root_id" --arg id "$other" \
    '. + [{id:$id,kind:9,pubkey:$p,tags:[["h",$c],["opc-event","evt_456"],["opc-issue","OPC-4"]],reply_to:$r}]' <<<"$saved")
lookup="$(main buzz-feedback resolve --channel "$channel" --event "$feedback_id")"
jq -e '.decision == "linked" and .issues[0].identifier == "OPC-3"' <<<"$lookup" >/dev/null ||
    fail "direct reply to one notification was confused by a different ticket in the same thread"
fixture=$(jq --arg r "$root_id" '.[2] |= (.reply_to=$r | del(.thread_root))' <<<"$fixture")
lookup="$(main buzz-feedback resolve --channel "$channel" --event "$feedback_id")"
jq -e '.decision == "ambiguous" and (.issues|length) == 2' <<<"$lookup" >/dev/null ||
    fail "multiple linked issues were not flagged as ambiguous"
if (main buzz-feedback continue --channel "$channel" --event "$feedback_id" --issue OPC-3); then fail "agent guess resolved ambiguity"; fi
fixture=$(jq '.[2].content = "OPC-3: volume zero still plays"' <<<"$fixture")
lookup="$(main buzz-feedback resolve --channel "$channel" --event "$feedback_id")"
jq -e '.decision == "linked" and .issues[0].identifier == "OPC-3"' <<<"$lookup" >/dev/null ||
    fail "operator could not disambiguate the feedback"
pass "ambiguous linked tickets require the operator's explicit choice"

rm -f "$scratch/write"
fixture="$saved"
issue_company="other-company"
if (main buzz-feedback continue --channel "$channel" --event "$feedback_id" --issue OPC-3); then fail "cross-company issue continued"; fi
[[ ! -e "$scratch/write" ]] || fail "cross-company issue was mutated"
unset issue_company
fixture=$(jq --arg other "$other" '.[2].pubkey=$other' <<<"$saved")
if (main buzz-feedback continue --channel "$channel" --event "$feedback_id" --issue OPC-3); then fail "other sender continued ticket"; fi
[[ ! -e "$scratch/write" ]] || fail "unauthorized feedback wrote to Paperclip"
fixture=$(jq --arg other "$other" '.[1].pubkey=$other' <<<"$saved")
if (main buzz-feedback continue --channel "$channel" --event "$feedback_id" --issue OPC-3); then fail "forged notifier tag chose ticket"; fi
[[ ! -e "$scratch/write" ]] || fail "forged notifier wrote to Paperclip"
pass "unauthorized sender and forged notifier cannot mutate tickets"

fixture="$saved"
issue_status=done
work_products='[{"reviewState":"approved"}]'
if (main buzz-feedback continue --channel "$channel" --event "$feedback_id" --issue OPC-3); then fail "accepted delivery was reopened"; fi
[[ ! -e "$scratch/write" ]] || fail "accepted delivery was mutated"
work_products='[]'
main buzz-feedback continue --channel "$channel" --event "$feedback_id" --issue OPC-3 >/dev/null
jq -e '.resume == true and (.body | contains("Volume at zero still plays"))' "$scratch/write" >/dev/null ||
    fail "premature done was not resumed through Paperclip"
pass "only unaccepted done work is eligible for native resume"

echo "opc-paperclip: ok"
