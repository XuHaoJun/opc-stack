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
trap 'rm -f "$DESC" "$scratch/paperclip.pub" "$scratch/agent.pub" "$scratch/relay.pub" "$scratch/write" "$scratch/writes"; rmdir "$scratch"' EXIT
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
                --arg company "${issue_company:-test-company}" --arg agent "${issue_agent-engineer-1}" \
                '{id:$id,identifier:"OPC-3",companyId:$company,projectId:"project-1",status:$status,title:"Volume control",labelIds:["l0"]}
                 + (if $agent != "" then {assigneeAgentId:$agent} else {assigneeUserId:"board-user"} end)' ;;
        "GET /issues/$issue_id/runs") printf '%s\n' "${issue_runs:-[]}" ;;
        "GET /issues/OPC-4")
            printf '%s\n' '{"id":"30000000-0000-4000-8000-000000000000","identifier":"OPC-4","companyId":"test-company","projectId":"project-2","status":"in_review"}' ;;
        "GET /issues/$issue_id/comments")
            jq -nc --arg c "$channel" --arg id "${persisted_root:-$root_id}" \
                '[{authorUserId:"board-user",body:("BUZZ_CHANNEL: "+$c+"\nBUZZ_EVENT: "+$id)}]' ;;
        "GET /issues/$issue_id/work-products") printf '%s\n' "${work_products:-[]}" ;;
        "GET /companies/test-company/labels") echo '[{"id":"l-prev","name":"preview"}]' ;;
        "PATCH /issues/$issue_id "*|"POST /issues/$issue_id/comments "*)
            printf '%s %s\n' "$1" "$3" >>"$scratch/writes"
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

# in_review handed to the owner's user returns to the agent of the newest run
rm -f "$scratch/write"
issue_status=in_review issue_agent=""
issue_runs='[{"agentId":"other","status":"succeeded","createdAt":"2026-11-19T00:00:00Z","finishedAt":"2026-11-19T00:10:00Z"},{"agentId":"engineer-1","status":"succeeded","createdAt":"2026-11-20T01:00:00Z","finishedAt":"2026-11-20T02:00:00Z"},{"agentId":"flaky","status":"failed","createdAt":"2026-11-20T03:00:00Z","finishedAt":"2026-11-20T03:01:00Z"},{"agentId":"flaky","status":"cancelled","createdAt":"2026-11-20T04:00:00Z","finishedAt":null}]'
main buzz-feedback continue --channel "$channel" --event "$feedback_id" --issue OPC-3 >/dev/null
jq -e '.status=="todo" and .assigneeAgentId=="engineer-1" and .assigneeUserId==null' "$scratch/write" >/dev/null ||
    fail "in_review rework did not return to the newest run's agent"
rm -f "$scratch/write"
issue_runs='[{"agentId":"flaky","status":"failed","createdAt":"2026-11-20T03:00:00Z"}]'
if (main buzz-feedback continue --channel "$channel" --event "$feedback_id" --issue OPC-3); then fail "failed-only runs picked an agent"; fi
[[ ! -e "$scratch/write" ]] || fail "failed-only rework wrote"
issue_agent=engineer-1 issue_runs='[{"agentId":"flaky","status":"failed","createdAt":"2026-11-20T03:00:00Z"}]'
main buzz-feedback continue --channel "$channel" --event "$feedback_id" --issue OPC-3 >/dev/null
jq -e '.assigneeAgentId=="engineer-1"' "$scratch/write" >/dev/null || fail "fallback to existing assignee failed"
rm -f "$scratch/write"; issue_agent="" issue_runs='[]'
if (main buzz-feedback continue --channel "$channel" --event "$feedback_id" --issue OPC-3); then fail "rework with no runs and no agent proceeded"; fi
[[ ! -e "$scratch/write" ]] || fail "no-agent rework wrote"
# a done ticket handed off to the owner (late preview reopen) goes back to the delivering agent
issue_status=done issue_agent="" issue_runs='[{"agentId":"engineer-1","status":"succeeded","createdAt":"2026-11-20T01:00:00Z","finishedAt":"2026-11-20T02:00:00Z"}]'
main buzz-feedback continue --channel "$channel" --event "$feedback_id" --issue OPC-3 >/dev/null
jq -e '.status=="todo" and .assigneeAgentId=="engineer-1" and .assigneeUserId==null and .resume==true
    and (.comment | contains("Volume at zero still plays")) and (.commentClientRequestId | length > 0)' "$scratch/write" >/dev/null ||
    fail "owner-assigned done ticket was not resumed to the delivering agent: $(cat "$scratch/write")"
rm -f "$scratch/write"
issue_runs='[{"agentId":"flaky","status":"failed","createdAt":"2026-11-20T03:00:00Z"}]'
if (main buzz-feedback continue --channel "$channel" --event "$feedback_id" --issue OPC-3); then fail "owner-assigned done with no succeeded run proceeded"; fi
[[ ! -e "$scratch/write" ]] || fail "owner-assigned done with no succeeded run wrote"
issue_status=in_review issue_runs='[{"agentId":"engineer-1","status":"succeeded","createdAt":"2026-11-20T01:00:00Z"}]'
main buzz-feedback continue --channel "$channel" --event "$feedback_id" --issue OPC-3 >/dev/null
jq -e 'has("resume") | not' "$scratch/write" >/dev/null || fail "in_review rework must not send resume"
rm -f "$scratch/write"
issue_status=todo
if (main buzz-feedback continue --channel "$channel" --event "$feedback_id" --issue OPC-3); then fail "todo with no agent assignee proceeded"; fi
unset issue_status issue_agent issue_runs
rm -f "$scratch/write"
pass "in_review rework returns to the delivering agent"

# --preview: a late preview of a done ticket must carry the preview label, or
# the reopened engineer re-finishes as done instead of handing off in_review.
rm -f "$scratch/write" "$scratch/writes"
issue_status=done issue_agent="" issue_runs='[{"agentId":"engineer-1","status":"succeeded","createdAt":"2026-11-20T01:00:00Z","finishedAt":"2026-11-20T02:00:00Z"}]'
main buzz-feedback continue --channel "$channel" --event "$feedback_id" --issue OPC-3 --preview >/dev/null
[[ "$(wc -l <"$scratch/writes")" == 1 ]] || fail "--preview reopen must be one write: $(cat "$scratch/writes")"
jq -e '.status=="todo" and .assigneeAgentId=="engineer-1" and .resume==true and (.labelIds|sort)==["l-prev","l0"]' "$scratch/write" >/dev/null ||
    fail "--preview reopen did not merge the preview label into the same PATCH: $(cat "$scratch/write")"
rm -f "$scratch/write" "$scratch/writes"
main buzz-feedback continue --channel "$channel" --event "$feedback_id" --issue OPC-3 >/dev/null
jq -e 'has("labelIds") | not' "$scratch/write" >/dev/null || fail "continue without --preview touched labels"
# done with an agent assignee goes through the comment path: label first, then the waking comment
rm -f "$scratch/write" "$scratch/writes"
issue_agent=engineer-1
main buzz-feedback continue --channel "$channel" --event "$feedback_id" --issue OPC-3 --preview >/dev/null
[[ "$(sed -n 1p "$scratch/writes" | cut -d' ' -f1)" == PATCH && "$(sed -n 2p "$scratch/writes" | cut -d' ' -f1)" == POST ]] ||
    fail "--preview comment path must label before the waking comment: $(cat "$scratch/writes")"
sed -n 1p "$scratch/writes" | cut -d' ' -f2- | jq -e '(.labelIds|sort)==["l-prev","l0"] and (has("status")|not)' >/dev/null ||
    fail "--preview label PATCH wrong: $(cat "$scratch/writes")"
if (main buzz-feedback resolve --channel "$channel" --event "$feedback_id" --preview >/dev/null 2>&1); then fail "resolve accepted --preview"; fi
unset issue_status issue_agent issue_runs
rm -f "$scratch/write" "$scratch/writes"
pass "buzz-feedback continue --preview labels the reopened ticket (merged, same write)"
awk '/^4\. Owner wants a preview of a `done` ticket/,/^### /' patches/buzz/skills/paperclip-api/SKILL.md \
    | tr '\n' ' ' | grep -q 'buzz-feedback continue --channel … --event … *--issue OPC-N --preview' ||
    fail "skill late-preview step does not reopen with buzz-feedback continue --preview"
pass "skill late-preview step reopens with --preview"

# ── ticket preview ───────────────────────────────────────────────────────
export OPC_PREVIEW_PORT_BASE=21012 OPC_PREVIEW_PORT_END=21015
export OPC_PREVIEW_POLL_SECONDS=0 OPC_PREVIEW_START_TIMEOUT=2

svc="$(preview_service_json 21012 http://100.92.16.32)"
jq -e '.name=="preview" and .port==21012 and .reuseScope=="execution_workspace"
    and .expose.urlTemplate=="http://100.92.16.32:{{port}}" and .command=="opc-preview-run"
    and .lifecycle=="shared" and .cwd=="." and .readiness.urlTemplate=="http://127.0.0.1:{{port}}"' <<<"$svc" >/dev/null \
    || fail "preview_service_json shape wrong: $svc"
[[ "$(preview_pick_port "" '[21012,21013]')" == 21014 ]] || fail "pick lowest free port"
[[ "$(preview_pick_port 21015 '[21012]')" == 21015 ]] || fail "pick preferred port when free"
[[ "$(preview_pick_port 21012 '[21012]')" == 21013 ]] || fail "preferred but held falls to lowest free"
rc=0; preview_pick_port "" '[21012,21013,21014,21015]' >/dev/null || rc=$?
[[ "$rc" == 5 ]] || fail "all ports held must exit 5 (got $rc)"
[[ "$(PAPERCLIP_PUBLIC_URL=http://100.92.16.32:3100 DEVENV_HTTP_PUBLIC_HOST= preview_public_base)" == http://100.92.16.32 ]] \
    || fail "public base from PAPERCLIP_PUBLIC_URL"
[[ "$(DEVENV_HTTP_PUBLIC_HOST=box preview_public_base)" == http://box ]] || fail "public base from DEVENV_HTTP_PUBLIC_HOST"
pass "preview helpers"

pv="$scratch/pv"; mkdir -p "$pv"
pv_reset() { rm -f "$pv"/*; pv_cfg=null; pv_ws_status=active; pv_issue_status=in_progress; pv_live_polls=0; pv_start_rc=0; pv_other_port=21012; pv_running_port=21013; pv_state=running; pv_ws_id=ws-1; pv_other_ports="21012"; pv_url_host=http://h; pv_orphan=""; }
preview_probe_url() { printf '%s\n' "$1" >>"$pv/probes"; return "${pv_probe_rc:-0}"; }
api_request() {
    case "$1 $2" in
        "GET /issues/OPC-3")
            jq -nc --arg ws "$pv_ws_id" --arg st "$pv_issue_status" '{id:"issue-3",identifier:"OPC-3",status:$st,labelIds:["l0"],executionWorkspaceId:(if $ws=="" then null else $ws end)}' ;;
        "GET /companies/test-company/live-runs?minCount=0&limit=50")
            echo x >>"$pv/live_polls"
            if [[ "$(wc -l <"$pv/live_polls")" -le "$pv_live_polls" ]]; then echo '[{"id":"run-1","issueId":"issue-3","status":"running"}]'
            else echo '[{"id":"run-2","issueId":"issue-other","status":"running"}]'; fi ;;
        "GET /issues/issue-9") echo '{"id":"issue-9","identifier":"OPC-9"}' ;;
        "GET /issues/issue-3") echo '{"id":"issue-3","identifier":"OPC-3"}' ;;
        "GET /execution-workspaces/ws-1")
            jq -nc --arg st "$pv_state" --argjson port "$pv_running_port" --argjson cfg "$pv_cfg" \
                --arg started "$([ -f "$pv/start" ] && echo 1)" \
                --arg wsst "$pv_ws_status" --arg uh "$pv_url_host" '
                {id:"ws-1",status:$wsst,sourceIssueId:"issue-3",branchName:"feat/x",config:$cfg,
                 runtimeServices:(if $started=="1" then
                   [{serviceName:"preview",status:$st,port:$port,url:($uh+":"+($port|tostring)),
                     id:"rs-1",updatedAt:"2026-11-20T00:00:00Z"}] else [] end)}' ;;
        "GET /companies/test-company/execution-workspaces")
            jq -nc --arg ports "$pv_other_ports" --arg own "$([ -f "$pv/start" ] && echo 1)" --arg orphan "$pv_orphan" '
                [($ports|split(" ")|map(select(.!="")|tonumber)|to_entries[]) as $e
                 | {id:("other-"+($e.key|tostring)),
                    sourceIssueId:(if $orphan != "" and $e.key == 0 then null else "issue-9" end),
                    runtimeServices:[{serviceName:"preview",status:"running",port:$e.value}]}]
                + (if $own=="1" then [{id:"ws-1",sourceIssueId:"issue-3",
                    runtimeServices:[{serviceName:"preview",status:"running",port:21013}]}] else [] end)'  ;;
        "GET /companies/test-company/labels") echo '[{"id":"l-prev","name":"preview"}]' ;;
        "PATCH /execution-workspaces/ws-1")
            if jq -e 'has("status")' <<<"$3" >/dev/null; then printf '%s\n' "$3" >"$pv/status_patch"; fi
            printf '%s\n' "$3" >>"$pv/patch" ;;
        "PATCH /issues/issue-3") printf '%s\n' "$3" >"$pv/issue_patch" ;;
        *) echo "unstubbed: $*" >&2; return 1 ;;
    esac
}

api_request_body() {
    case "$1 $2" in
        "POST /execution-workspaces/ws-1/runtime-services/start")
            printf '%s\n' "$3" >"$pv/start_body"
            if [[ "$pv_start_rc" != 0 ]]; then echo '{"error":"Runtime service could not bind 0.0.0.0:21013"}'; return 1; fi
            touch "$pv/start"; echo '{}' ;;
        "POST /execution-workspaces/ws-1/runtime-services/stop") printf '%s\n' "$3" >"$pv/stop"; echo '{}' ;;
        *) echo "unstubbed body: $*" >&2; return 1 ;;
    esac
}

pv_reset
out="$(main preview up --issue OPC-3)" || fail "preview up failed"
jq -e '.port==21013 and .url=="http://h:21013" and .workspaceId=="ws-1" and .status=="running" and .branchName=="feat/x" and .probe=="public"' <<<"$out" >/dev/null \
    || fail "preview up output wrong: $out"
[[ "$(cat "$pv/probes")" == http://h:21013 ]] || fail "public preview probed elsewhere: $(cat "$pv/probes")"
jq -e '.config.workspaceRuntime.services[0].port==21013 and (.config|has("desiredState")|not)
    and .config.serviceStates=={"0":"running"}' "$pv/patch" >/dev/null \
    || fail "preview up PATCH body wrong: $(cat "$pv/patch")"
jq -e '.labelIds | index("l-prev") and index("l0")' "$pv/issue_patch" >/dev/null || fail "preview label not added"
jq -e '.serviceIndex==0' "$pv/start_body" >/dev/null || fail "start body lacks the preview selector: $(cat "$pv/start_body")"
pass "preview up picks a free port, starts, probes, labels"

pv_reset; pv_cfg='{"workspaceRuntime":{"services":[{"name":"web","port":3000}]}}'
main preview up --issue OPC-3 >/dev/null || fail "preview up with another service failed"
jq -e '.config.workspaceRuntime.services | length==2 and .[0].name=="web" and .[1].name=="preview"' "$pv/patch" >/dev/null \
    || fail "other services were not preserved"
jq -e '.serviceIndex==1' "$pv/start_body" >/dev/null || fail "start targeted the wrong service: $(cat "$pv/start_body")"
pass "preview up targets only the preview service among several"

# Re-up with preview already configured at index 1 behind a service with no
# serviceStates entry: indices stay put, the other service is not made
# desired-running (Paperclip fills a missing state from desiredState).
pv_reset; pv_cfg='{"workspaceRuntime":{"services":[{"name":"web","port":3000},{"name":"preview","port":21013,"command":"old"}]},"serviceStates":{"1":"stopped"}}'
main preview up --issue OPC-3 >/dev/null || fail "re-up with preview at index 1 failed"
jq -e '.config.workspaceRuntime.services | length==2 and .[0].name=="web" and .[0].port==3000
    and .[1].name=="preview" and .[1].command=="opc-preview-run"' "$pv/patch" >/dev/null \
    || fail "re-up moved services: $(cat "$pv/patch")"
jq -e '.config.serviceStates=={"0":"stopped","1":"running"} and (.config|has("desiredState")|not)' "$pv/patch" >/dev/null \
    || fail "re-up serviceStates wrong (other service must not be running): $(cat "$pv/patch")"
jq -e '.serviceIndex==1' "$pv/start_body" >/dev/null || fail "re-up started the wrong index: $(cat "$pv/start_body")"
pv_reset; pv_cfg='{"workspaceRuntime":{"services":[{"name":"web"},{"name":"db"},{"name":"preview"}]},"serviceStates":{"0":"manual","1":"running"}}'
main preview up --issue OPC-3 >/dev/null || fail "re-up with explicit states failed"
jq -e '.config.serviceStates=={"0":"manual","1":"running","2":"running"}' "$pv/patch" >/dev/null \
    || fail "re-up did not keep explicit states: $(cat "$pv/patch")"
pv_reset; pv_cfg='{"workspaceRuntime":{"commands":[{"name":"web","kind":"service"}]}}'
rc=0; (main preview up --issue OPC-3 >/dev/null 2>&1) || rc=$?
[[ "$rc" == 4 && ! -e "$pv/patch" && ! -e "$pv/start" ]] || fail "commands[] workspace must be refused untouched (rc=$rc)"
pass "preview up replaces the preview entry in place with explicit per-index states"

# Default install: PAPERCLIP_PUBLIC_URL=http://localhost:3100. From the front
# door's netns, localhost is not the host; probe the same port on paperclip.
for host in http://localhost http://127.0.0.1 "http://[::1]"; do
    pv_reset; pv_url_host="$host"
    out="$(PAPERCLIP_PUBLIC_URL="$host:3100" main preview up --issue OPC-3)" || fail "loopback preview up ($host) failed"
    [[ "$(cat "$pv/probes")" == http://paperclip:21013 ]] || fail "loopback ($host) probed $(cat "$pv/probes")"
    jq -e --arg u "$host:21013" '.url==$u and .probe=="internal"' <<<"$out" >/dev/null || fail "loopback output wrong: $out"
done
pass "preview up probes a loopback public URL through the compose name, reports the public URL"

pv_reset; pv_running_port=54321
if err="$(main preview up --issue OPC-3 2>&1 >/dev/null)"; then fail "port fallback was published"; fi
grep -qi 'port mismatch' <<<"$err" || fail "no port mismatch message: $err"
pass "preview up refuses an auto-port fallback"

pv_reset; pv_ws_id=""
rc=0; err="$(main preview up --issue OPC-3 2>&1 >/dev/null)" || rc=$?
[[ "$rc" == 3 ]] && grep -q 'no usable execution workspace' <<<"$err" && grep -q 'buzz-feedback continue' <<<"$err" \
    || fail "no-workspace case wrong (rc=$rc): $err"
[[ ! -e "$pv/status_patch" ]] || fail "a workspace status was PATCHed"
pass "preview up on an issue without a workspace points at buzz-feedback continue"

pv_reset; pv_issue_status=in_review; pv_live_polls=2
main preview up --issue OPC-3 >/dev/null || fail "preview up after an in_review hand-off failed"
[[ "$(wc -l <"$pv/live_polls")" == 3 ]] || fail "in_review preview up did not wait for the hand-off run ($(wc -l <"$pv/live_polls") polls)"
pv_reset
main preview up --issue OPC-3 >/dev/null || fail "preview up failed"
[[ ! -e "$pv/live_polls" ]] || fail "in_progress preview up waited on live runs"
pass "preview up waits for the hand-off run to end, only in in_review"

for case in "issue done" "issue cancelled" "workspace archived" "workspace cleanup_failed"; do
    pv_reset
    case "$case" in
        "issue "*) pv_issue_status="${case#issue }" ;;
        *) pv_ws_status="${case#workspace }" ;;
    esac
    rc=0; err="$(main preview up --issue OPC-3 2>&1 >/dev/null)" || rc=$?
    [[ "$rc" == 3 ]] && grep -q 'buzz-feedback continue' <<<"$err" && grep -q 'no usable execution workspace' <<<"$err" \
        || fail "$case must refuse with exit 3 and the continue path (rc=$rc): $err"
    [[ ! -e "$pv/patch" && ! -e "$pv/start" ]] || fail "$case wrote to Paperclip"
    if [[ "$case" == "issue done" ]]; then
        jq -e '(.labelIds|sort)==["l-prev","l0"]' "$pv/issue_patch" >/dev/null 2>&1 ||
            fail "done ticket was refused without the preview label: $(cat "$pv/issue_patch" 2>/dev/null)"
    else
        [[ ! -e "$pv/issue_patch" ]] || fail "$case labelled the ticket"
    fi
done
pass "preview up refuses done/cancelled tickets and closed workspaces, pointing at buzz-feedback continue (done gets labelled first)"

pv_reset; pv_state=starting
rc=0; err="$(main preview up --issue OPC-3 2>&1 >/dev/null)" || rc=$?
[[ "$rc" == 4 ]] && grep -q 'stuck in starting' <<<"$err" && grep -q 'preview down --issue OPC-3' <<<"$err" \
    || fail "stuck-starting but serving must name the remedy (rc=$rc): $err"
pv_reset; pv_state=starting; pv_probe_rc=7
rc=0; err="$(main preview up --issue OPC-3 2>&1 >/dev/null)" || rc=$?
[[ "$rc" == 4 ]] && grep -q 'did not start within' <<<"$err" || fail "stuck-starting and dead must time out plainly (rc=$rc): $err"
unset pv_probe_rc
pass "preview up names the upstream stuck-starting race when the URL already answers"

pv_reset; pv_other_ports="21012 21013 21014 21015"
rc=0; err="$(main preview up --issue OPC-3 2>&1 >/dev/null)" || rc=$?
[[ "$rc" == 5 ]] && grep -q OPC-9 <<<"$err" || fail "all-ports-held case wrong (rc=$rc): $err"
pv_reset; pv_other_ports="21012 21013 21014 21015"; pv_orphan=1
rc=0; err="$(main preview up --issue OPC-3 2>&1 >/dev/null)" || rc=$?
[[ "$rc" == 5 ]] && grep -q 'workspace other-0' <<<"$err" && grep -q OPC-9 <<<"$err" && ! grep -q unknown <<<"$err" \
    || fail "holder without a source issue must be named by workspace id (rc=$rc): $err"
[[ ! -e "$pv/patch" && ! -e "$pv/start" ]] || fail "port exhaustion still wrote to Paperclip"
pass "preview up with all ports held exits 5 naming holders, writes nothing"

pv_reset; pv_start_rc=1
rc=0; out="$(main preview up --issue OPC-3 2>"$pv/err")" || rc=$?
[[ "$rc" == 4 ]] && grep -q 'could not bind' "$pv/err" && [[ -z "$out" ]] || fail "failed start case wrong (rc=$rc): $(cat "$pv/err")"
pass "preview up surfaces Paperclip's start error text"

pv_reset; pv_state=stopped
rc=0; out="$(main preview up --issue OPC-3 2>"$pv/err")" || rc=$?
[[ "$rc" == 4 && -z "$out" ]] || fail "service that stopped right after start must fail fast (rc=$rc)"
pass "preview up fails fast when the service ends up stopped"

pv_reset; pv_probe_rc=22
rc=0; (main preview up --issue OPC-3 >/dev/null 2>&1) || rc=$?
out="$(main preview up --issue OPC-3 2>/dev/null)" && fail "unreachable URL still succeeded"
[[ "$rc" == 4 && -z "$out" ]] || fail "unreachable public URL must exit 4 with empty stdout (got $rc)"
unset pv_probe_rc
pass "preview up fails when the public URL does not answer"

pv_reset; touch "$pv/start"; pv_cfg='{"workspaceRuntime":{"services":[{"name":"web","port":3000},{"name":"preview","port":21013}]}}'
out="$(main preview down --issue OPC-3)" || fail "preview down failed"
jq -e '.status=="stopped" and .identifier=="OPC-3"' <<<"$out" >/dev/null || fail "down output wrong: $out"
[[ -s "$pv/stop" ]] || fail "down did not POST runtime-services/stop"
jq -e '.runtimeServiceId=="rs-1"' "$pv/stop" >/dev/null || fail "stop is not scoped to the preview runtime service: $(cat "$pv/stop")"
jq -e '.config.serviceStates=={"1":"stopped"} and (.config|has("desiredState")|not)' "$pv/patch" >/dev/null \
    || fail "down did not scope the stopped state to the preview index: $(cat "$pv/patch")"
pv_reset
main preview down --issue OPC-3 >/dev/null || fail "down is not idempotent with no running service"
pass "preview down stops the service and records desiredState"

pv_reset; touch "$pv/start"
out="$(main preview status --issue OPC-3)" || fail "preview status failed"
jq -e 'length==1 and .[0].identifier=="OPC-3" and .[0].port==21013 and .[0].status=="running"' <<<"$out" >/dev/null \
    || fail "status output wrong: $out"
pv_reset; pv_orphan=1; pv_other_ports="21012 21014"
out="$(main preview status)" || fail "preview status (all) failed"
jq -e 'any(.[]; .identifier==null and .workspaceId=="other-0" and .port==21012) and any(.[]; .identifier=="OPC-9")' <<<"$out" >/dev/null \
    || fail "status dropped a preview without a source issue: $out"
pass "preview status lists preview services (workspace id when there is no source issue)"

# The probe counts only a 2xx; a redirect is not followed and fails.
probe_fn="$(declare -f preview_probe_url)"
unset -f preview_probe_url
# shellcheck disable=SC1091
eval "$(sed -n '/^preview_probe_url() {/,/^}/p' patches/buzz/opc-paperclip)"
curl() { printf '%s' "$probe_code"; }
probe_code=302; preview_probe_url http://x && fail "a 302 counted as a live preview"
probe_code=500; preview_probe_url http://x && fail "a 500 counted as a live preview"
probe_code=204; preview_probe_url http://x || fail "a 204 did not count"
unset -f curl
eval "$probe_fn"
grep -A4 '^preview_probe_url() {' patches/buzz/opc-paperclip | grep -q -- "-w '%{http_code}'" || fail "probe does not read the status code"
grep -A4 '^preview_probe_url() {' patches/buzz/opc-paperclip | grep -q -- ' -L' && fail "probe follows redirects"
pass "preview probe requires a 2xx"

grep -q '"status":"active"' patches/hermes/opc-paperclip && fail "helper still PATCHes a workspace status"
api_request() { return 1; }
rc=0; out="$(main preview status --issue OPC-3 2>/dev/null)" || rc=$?
[[ "$rc" != 0 && -z "$out" ]] || fail "status swallowed a failed issue lookup (rc=$rc out=$out)"
pass "preview status propagates a failed issue lookup"
rm -rf "$pv"

# ── prototype preview (front door opens/closes what the Prototyper registered) ──
pp="$scratch/pp"; mkdir -p "$pp"
pp_reset() { rm -f "$pp"/*; pp_svcs='[{"name":"api","port":21005},{"name":"preview","port":21003,"expose":{"urlTemplate":"http://box:21003"}}]'; pp_result=running; pp_port=21003; pp_archived=null; pp_start_rc=0; }
preview_probe_url() { printf '%s\n' "$1" >>"$pp/probes"; return "${pp_probe_rc:-0}"; }
api_request() {
    case "$1 $2" in
        "GET /companies/test-company/projects")
            jq -nc --argjson a "$pp_archived" '[{id:"p1",name:"demo",archivedAt:$a},{id:"p2",name:"other",archivedAt:null}]' ;;
        "GET /projects/p1")
            jq -nc --argjson s "$pp_svcs" --arg st "$pp_result" --argjson port "$pp_port" \
                --arg started "$([ -f "$pp/start" ] && echo 1)" '
                {id:"p1",workspaces:[{id:"w1",isPrimary:true,runtimeConfig:{workspaceRuntime:{services:$s}},
                  runtimeServices:(if $started=="1" then [{serviceName:"preview",status:$st,port:$port,
                    url:("http://box:"+($port|tostring)),updatedAt:"t"}] else [] end)}]}' ;;
        *) echo "unstubbed: $*" >&2; return 1 ;;
    esac
}
api_request_body() {
    case "$1 $2" in
        "POST /projects/p1/workspaces/w1/runtime-services/start")
            printf '%s\n' "$3" >"$pp/start_body"
            if [[ "$pp_start_rc" != 0 ]]; then echo '{"error":"spawn failed"}'; return 1; fi
            touch "$pp/start"; echo '{}' ;;
        "POST /projects/p1/workspaces/w1/runtime-services/stop") printf '%s\n' "$3" >"$pp/stop"; echo '{}' ;;
        *) echo "unstubbed body: $*" >&2; return 1 ;;
    esac
}

pp_reset
out="$(main preview up --prototype demo)" || fail "prototype preview up failed"
jq -e '.prototype=="demo" and .url=="http://box:21003" and .port==21003 and .status=="running"' <<<"$out" >/dev/null \
    || fail "prototype up output wrong: $out"
jq -e '.serviceIndex==1' "$pp/start_body" >/dev/null || fail "prototype start not scoped to the preview: $(cat "$pp/start_body")"
[[ "$(cat "$pp/probes")" == http://box:21003 ]] || fail "prototype preview probed elsewhere: $(cat "$pp/probes")"
pass "preview up --prototype starts only the registered preview and probes it"

pp_reset; pp_svcs='[{"name":"api","port":21005}]'
rc=0; out="$(main preview up --prototype demo 2>&1)" || rc=$?
[[ "$rc" == 3 ]] && grep -q 'prototype expose demo' <<<"$out" || fail "unregistered prototype must exit 3 pointing at prototype expose (rc=$rc): $out"
[[ ! -e "$pp/start_body" ]] || fail "unregistered prototype was started"
pp_reset; pp_archived='"2026-11-01T00:00:00Z"'
rc=0; ( main preview up --prototype demo ) >/dev/null 2>&1 || rc=$?
[[ "$rc" == 3 ]] || fail "archived prototype must exit 3 (got $rc)"
rc=0; ( main preview up --prototype nope ) >/dev/null 2>&1 || rc=$?
[[ "$rc" == 3 ]] || fail "unknown prototype must exit 3 (got $rc)"
pass "preview up --prototype refuses unknown, archived and unregistered prototypes"

pp_reset; pp_result=failed
rc=0; ( main preview up --prototype demo ) >/dev/null 2>&1 || rc=$?
[[ "$rc" == 4 ]] || fail "failed prototype start must exit 4 (got $rc)"
pp_reset; pp_port=39001
rc=0; out="$(main preview up --prototype demo 2>&1)" || rc=$?
[[ "$rc" == 4 ]] && grep -q 39001 <<<"$out" || fail "prototype port fallback must exit 4 (rc=$rc): $out"
pp_reset; pp_probe_rc=1
rc=0; ( main preview up --prototype demo ) >/dev/null 2>&1 || rc=$?
[[ "$rc" == 4 ]] || fail "unanswered prototype URL must exit 4 (got $rc)"
pp_probe_rc=0
pass "preview up --prototype fails on a failed start, a port fallback, or a dead URL"

pp_reset
out="$(main preview down --prototype demo)" || fail "prototype preview down failed"
jq -e '.prototype=="demo" and .status=="stopped"' <<<"$out" >/dev/null || fail "prototype down output wrong: $out"
jq -e '.serviceIndex==1' "$pp/stop" >/dev/null || fail "prototype stop not scoped to the preview: $(cat "$pp/stop")"
pp_reset; pp_svcs='[]'
main preview down --prototype demo >/dev/null || fail "down of an unregistered prototype must succeed"
[[ ! -e "$pp/stop" ]] || fail "down of an unregistered prototype POSTed a stop"
pass "preview down --prototype stops only the preview; no-op when unregistered"

pp_reset; touch "$pp/start"
out="$(main preview status --prototype demo)" || fail "prototype status failed"
jq -e '.prototype=="demo" and .status=="running" and .port==21003 and .url=="http://box:21003"' <<<"$out" >/dev/null \
    || fail "prototype status wrong: $out"
pp_reset
out="$(main preview status --prototype demo)" || fail "prototype status (stopped) failed"
jq -e '.status=="stopped" and .url=="http://box:21003"' <<<"$out" >/dev/null || fail "stopped prototype status wrong: $out"
pp_reset; pp_svcs='[]'
out="$(main preview status --prototype demo)" || fail "prototype status (unregistered) failed"
jq -e '.status=="unregistered"' <<<"$out" >/dev/null || fail "unregistered prototype status wrong: $out"
pass "preview status --prototype reports running / stopped / unregistered"
rm -rf "$pp"

echo "opc-paperclip: ok"
