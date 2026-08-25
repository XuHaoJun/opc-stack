#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
. "$(dirname "$0")/../scripts/load-env.sh"; opc_load_env ./.env
PASS=0 FAIL=0
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
assert_eq() { local label="$1" want="$2" got="$3"; [ "$want" = "$got" ] && ok "$label" || { bad "$label (want=$want got=$got)"; return 1; }; }
assert_contains() { local label="$1" needle="$2" haystack="$3"; [[ "$haystack" == *"$needle"* ]] && ok "$label" || { bad "$label (missing=$needle)"; return 1; }; }
assert_not_contains() { local label="$1" needle="$2" haystack="$3"; [[ "$haystack" != *"$needle"* ]] && ok "$label" || { bad "$label (found=$needle)"; return 1; }; }
CLI=patches/hermes/opc-paperclip
MODE=fixture
RUN_LIVE_AFTER_FIXTURE=0
# Fresh-install rehearsal sets OPC_WORKSPACE_ROUTING_EPHEMERAL=1; main-stack live runs remain strict by default.
case "${1-}" in
  "") MODE=fixture; RUN_LIVE_AFTER_FIXTURE=1 ;;
  --fixture) MODE=fixture ;;
  --live) MODE=live ;;
  *) echo "usage: $0 [--fixture|--live]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  echo "usage: $0 [--fixture|--live]" >&2
  exit 2
fi

LIVE_TMPDIR=""
LIVE_RESTORE_NEEDED=0
LIVE_AGENT_ID=""
LIVE_COMPANY_ID=""
LIVE_ORIGINAL_AGENT=""
LIVE_PROJECT_ID=""
LIVE_PREEXISTING_PROJECT_ID=""
LIVE_PROJECT_ISSUE_IDS=""
LIVE_TEST_PROJECT_IDS=""
LIVE_PROTO_NAMES=""
LIVE_TEST_AGENT_IDS=""
LIVE_ADAPTER_SCRIPT=""
LIVE_MARKER=""
LIVE_CREATED_ISSUE_ID=""
LIVE_CREATED_AGENT_ID=""
LIVE_RELEASE=""
LIVE_RECORD=""
LIVE_CLEANUP_STATUS=0
LIVE_RESPONSE_BODY=""
LIVE_RESPONSE_STATUS=""
LIVE_BOARD_KEY=""
LIVE_BASE=""
LIVE_PREEXISTING_SNAPSHOT=""
LIVE_PREEXISTING_RESTORE_NEEDED=0
LIVE_OWNERSHIP_UNKNOWN=0
live_api() {
  local method="$1" path="$2" body="${3-}"
  if [ "$method" = GET ] || [ "$method" = DELETE ]; then
    curl -fsS -X "$method" -H "Authorization: Bearer $LIVE_BOARD_KEY" \
      "$LIVE_BASE$path"
  else
    curl -fsS -X "$method" -H "Authorization: Bearer $LIVE_BOARD_KEY" \
      -H 'Content-Type: application/json' --data-binary "$body" "$LIVE_BASE$path"
  fi
}

live_mutation() {
  local method="$1" path="$2" body="${3-}" response status
  response="$(mktemp "$LIVE_TMPDIR/response.XXXXXX")"
  if [ -n "$body" ]; then
    status="$(curl -sS -o "$response" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $LIVE_BOARD_KEY" -H 'Content-Type: application/json' \
      --data-binary "$body" "$LIVE_BASE$path")" || status=000
  else
    status="$(curl -sS -o "$response" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $LIVE_BOARD_KEY" "$LIVE_BASE$path")" || status=000
  fi
  LIVE_RESPONSE_BODY="$(cat "$response")"
  rm -f "$response"
  LIVE_RESPONSE_STATUS="$status"
  case "$status" in 2??) return 0 ;; *) return 1 ;; esac
}
live_key_mutation() {
  local key="$1" method="$2" path="$3" body="${4-}" response status
  response="$(mktemp "$LIVE_TMPDIR/response.XXXXXX")"
  if [ -n "$body" ]; then
    status="$(curl -sS -o "$response" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
      --data-binary "$body" "$LIVE_BASE$path")" || status=000
  else
    status="$(curl -sS -o "$response" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $key" "$LIVE_BASE$path")" || status=000
  fi
  LIVE_RESPONSE_BODY="$(cat "$response")"
  rm -f "$response"
  LIVE_RESPONSE_STATUS="$status"
  case "$status" in 2??) return 0 ;; *) return 1 ;; esac
}
delete_and_verify() {
  local label="$1" delete_path="$2" verify_path="$3" expected="$4"
  if ! live_mutation DELETE "$delete_path"; then
    case "$LIVE_RESPONSE_STATUS" in
      404) ok "$label cleanup (already absent)" ; return 0 ;;
      *) bad "$label delete (HTTP $LIVE_RESPONSE_STATUS)"; LIVE_CLEANUP_STATUS=1; return 1 ;;
    esac
  fi
  if [ "$expected" = absent ]; then
    if live_mutation GET "$verify_path"; then
      bad "$label delete verification (record still present)"
      LIVE_CLEANUP_STATUS=1
      return 1
    fi
    case "$LIVE_RESPONSE_STATUS" in
      404) ;;
      *) bad "$label delete verification (HTTP $LIVE_RESPONSE_STATUS)"; LIVE_CLEANUP_STATUS=1; return 1 ;;
    esac
  fi
  ok "$label cleanup"
}
wake_issue() {
  local agent="$1" issue="$2"
  live_mutation POST "/agents/$agent/wakeup" \
    "{\"source\":\"on_demand\",\"triggerDetail\":\"manual\",\"payload\":{\"issueId\":\"$issue\"}}" ||
    { bad "wakeup issue $issue (HTTP $LIVE_RESPONSE_STATUS)"; return 1; }
}
create_issue() {
  local payload="$1" id project_id marker matches match_count
  live_mutation POST "/companies/$LIVE_COMPANY_ID/issues" "$payload" || return 1
  id="$(printf '%s' "$LIVE_RESPONSE_BODY" | jq -r '.id // empty')"
  if [ -z "$id" ]; then
    project_id="$(printf '%s' "$payload" | jq -er '.projectId // empty')" || return 1
    marker="$(printf '%s' "$payload" | jq -er '.description // empty')" || return 1
    [ -n "$project_id" ] && [ -n "$marker" ] || return 1
    if ! live_mutation GET "/companies/$LIVE_COMPANY_ID/issues?limit=1000"; then
      return 1
    fi
    matches="$(printf '%s' "$LIVE_RESPONSE_BODY" | jq -c --arg m "$marker" --arg p "$project_id" '
      if type != "array" then error("issue list is not an array") else
        [.[] | select(.projectId == $p and (.description // "") == $m
          and (.id | type == "string" and length > 0)) | .id]
      end')" || return 1
    match_count="$(printf '%s' "$matches" | jq -r 'length')" || return 1
    if [ "$match_count" -gt 0 ]; then
      LIVE_PROJECT_ISSUE_IDS="$LIVE_PROJECT_ISSUE_IDS $(printf '%s' "$matches" | jq -r '.[]')"
    fi
    if [ "$match_count" -ne 1 ]; then
      return 1
    fi
    id="$(printf '%s' "$matches" | jq -r '.[0]')"
    return 1
  fi
  LIVE_CREATED_ISSUE_ID="$id"
}
snapshot_preexisting_project() {
  local project_id="$1" project workspace_id policy metadata
  [ -n "$LIVE_TMPDIR" ] || { bad "snapshot pre-existing project (temporary directory unavailable)"; return 1; }
  if ! live_mutation GET "/projects/$project_id"; then
    bad "snapshot pre-existing project $project_id (HTTP $LIVE_RESPONSE_STATUS)"
    return 1
  fi
  project="$LIVE_RESPONSE_BODY"
  workspace_id="$(printf '%s' "$project" | jq -r '
    if (.primaryWorkspace? | type) == "object" then .primaryWorkspace.id
    else ([.workspaces // [] | .[] | select(.isPrimary == true)][0].id // empty) end
  ')" || return 1
  policy="$(printf '%s' "$project" | jq -c '.executionWorkspacePolicy // {}')" || return 1
  metadata="$(printf '%s' "$project" | jq -c '
    if (.primaryWorkspace? | type) == "object" then (.primaryWorkspace.metadata // {})
    else ([.workspaces // [] | .[] | select(.isPrimary == true)][0].metadata // {}) end
  ')" || return 1
  [ -n "$workspace_id" ] || { bad "snapshot pre-existing project $project_id (primary workspace missing)"; return 1; }
  printf '%s' "$project" | jq -e --arg w "$workspace_id" --argjson policy "$policy" --argjson metadata "$metadata" '
    {projectId:.id,workspaceId:$w,policy:$policy,metadata:$metadata}
    | .projectId | type == "string" and length > 0
  ' >/dev/null 2>&1 || {
    bad "snapshot pre-existing project $project_id (invalid state)"
    return 1
  }
  printf '%s' "$project" | jq -c --arg w "$workspace_id" --argjson policy "$policy" --argjson metadata "$metadata" \
    '{projectId:.id,workspaceId:$w,policy:$policy,metadata:$metadata}' >"$LIVE_PREEXISTING_SNAPSHOT"
  chmod 600 "$LIVE_PREEXISTING_SNAPSHOT"
  LIVE_PREEXISTING_RESTORE_NEEDED=1
  LIVE_PREEXISTING_PROJECT_ID="$project_id"
}
restore_preexisting_project() {
  [ "$LIVE_PREEXISTING_RESTORE_NEEDED" -eq 1 ] || return 0
  local snapshot project_id workspace_id policy metadata project workspace restore_status=0
  snapshot="$(cat "$LIVE_PREEXISTING_SNAPSHOT")" || {
    bad "restore pre-existing project (snapshot unreadable)"
    return 1
  }
  project_id="$(printf '%s' "$snapshot" | jq -r '.projectId')"
  workspace_id="$(printf '%s' "$snapshot" | jq -r '.workspaceId')"
  policy="$(printf '%s' "$snapshot" | jq -c '.policy')"
  metadata="$(printf '%s' "$snapshot" | jq -c '.metadata')"
  if ! live_mutation PATCH "/projects/$project_id" "$(jq -nc --argjson policy "$policy" '{executionWorkspacePolicy:$policy}')"; then
    bad "restore pre-existing project policy $project_id (HTTP $LIVE_RESPONSE_STATUS)"
    restore_status=1
  else
    project="$(live_api GET "/projects/$project_id" 2>/dev/null || true)"
    if [ "$(printf '%s' "$project" | jq -c '.executionWorkspacePolicy // {}' 2>/dev/null)" != "$policy" ]; then
      bad "restore exact pre-existing project policy $project_id (GET mismatch)"
      restore_status=1
    fi
  fi
  if ! live_mutation PATCH "/projects/$project_id/workspaces/$workspace_id" "$(jq -nc --argjson metadata "$metadata" '{metadata:$metadata}')"; then
    bad "restore pre-existing workspace metadata $workspace_id (HTTP $LIVE_RESPONSE_STATUS)"
    restore_status=1
  else
    project="$(live_api GET "/projects/$project_id" 2>/dev/null || true)"
    workspace="$(printf '%s' "$project" | jq -c --arg w "$workspace_id" '
      if (.primaryWorkspace? | type) == "object" and .primaryWorkspace.id == $w then .primaryWorkspace
      else ([.workspaces // [] | .[] | select(.id == $w)][0] // {}) end
    ' 2>/dev/null || true)"
    if [ "$(printf '%s' "$workspace" | jq -c '.metadata // {}' 2>/dev/null)" != "$metadata" ]; then
      bad "restore exact pre-existing workspace metadata $workspace_id (GET mismatch)"
      restore_status=1
    fi
  fi
  if [ "$restore_status" -eq 0 ]; then
    LIVE_PREEXISTING_RESTORE_NEEDED=0
    ok "restore exact pre-existing project policy and workspace metadata"
    return 0
  fi
  return 1
}
recover_live_ticket_ownership() {
  local repo="$1" marker="$2" canonical projects project_rows project_ids project_id repo_url \
    project_count issues issue_rows issue_ids issue_id existing_projects existing_issues live_identity
  existing_projects="$LIVE_TEST_PROJECT_IDS"
  existing_issues="$LIVE_PROJECT_ISSUE_IDS"
  canonical="$("$CLI" repo normalize "$repo" 2>/dev/null | jq -r '.identity // empty')" || canonical=""
  if [ -z "$canonical" ]; then
    bad "ticket ownership unknown after helper failure (repository identity unavailable)"
    LIVE_OWNERSHIP_UNKNOWN=1
    return 1
  fi
  if ! live_mutation GET "/companies/$LIVE_COMPANY_ID/projects"; then
    bad "ticket ownership unknown after helper failure (project API HTTP $LIVE_RESPONSE_STATUS)"
    LIVE_OWNERSHIP_UNKNOWN=1
    return 1
  fi
  projects="$LIVE_RESPONSE_BODY"
  if ! printf '%s' "$projects" | jq -e '
    type == "array"
    and all(.[]; type == "object"
      and (.id | type == "string" and length > 0)
      and ((.primaryWorkspace? == null)
        or ((.primaryWorkspace | type) == "object"
          and ((.primaryWorkspace.repoUrl? == null)
            or (.primaryWorkspace.repoUrl | type) == "string")))
      and ((.workspaces? == null)
        or ((.workspaces | type) == "array"
          and all(.workspaces[]; type == "object")))
    )
  ' >/dev/null 2>&1; then
    bad "ticket ownership unknown after helper failure (malformed project API response)"
    LIVE_OWNERSHIP_UNKNOWN=1
    return 1
  fi
  project_rows="$(printf '%s' "$projects" | jq -r '.[] | [.id, (.primaryWorkspace.repoUrl // ((.workspaces // []) | map(select(.isPrimary == true))[0].repoUrl // ""))] | @tsv')"
  project_ids="$(
    while IFS="$(printf '\t')" read -r project_id repo_url; do
      [ -n "$project_id" ] && [ -n "$repo_url" ] || continue
      live_identity="$("$CLI" repo normalize "$repo_url" 2>/dev/null | jq -r '.identity // empty' || true)"
      [ "$live_identity" = "$canonical" ] && printf '%s\n' "$project_id"
    done <<EOF
$project_rows
EOF
  )"
  project_count="$(printf '%s\n' "$project_ids" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$project_count" -ne 1 ]; then
    bad "ticket ownership unknown after helper failure (expected one canonical project, found $project_count)"
    LIVE_OWNERSHIP_UNKNOWN=1
    return 1
  fi
  project_id="$(printf '%s\n' "$project_ids" | sed '/^$/d')"
  case " $existing_projects " in
    *" $project_id "*) ;;
    *) LIVE_TEST_PROJECT_IDS="$LIVE_TEST_PROJECT_IDS $project_id" ;;
  esac
  [ -n "$LIVE_PROJECT_ID" ] || LIVE_PROJECT_ID="$project_id"
  if ! live_mutation GET "/companies/$LIVE_COMPANY_ID/issues?limit=1000"; then
    bad "ticket ownership unknown after helper failure (issue API HTTP $LIVE_RESPONSE_STATUS)"
    LIVE_OWNERSHIP_UNKNOWN=1
    return 1
  fi
  issues="$LIVE_RESPONSE_BODY"
  if ! printf '%s' "$issues" | jq -e '
    type == "array"
    and all(.[]; type == "object"
      and (.id | type == "string" and length > 0)
      and ((.description? == null) or (.description | type == "string"))
      and ((.projectId? == null) or (.projectId | type == "string"))
    )
  ' >/dev/null 2>&1; then
    bad "ticket ownership unknown after helper failure (malformed issue API response)"
    LIVE_OWNERSHIP_UNKNOWN=1
    return 1
  fi
  issue_rows="$(printf '%s' "$issues" | jq -r --arg marker "$marker" --arg project "$project_id" '
    .[] | select(.description == $marker and .projectId == $project) | .id
  ')"
  issue_ids="$(
    while IFS= read -r issue_id; do
      [ -n "$issue_id" ] || continue
      case " $existing_issues " in
        *" $issue_id "*) ;;
        *) printf '%s\n' "$issue_id" ;;
      esac
    done <<EOF
$issue_rows
EOF
  )"
  issue_count="$(printf '%s\n' "$issue_ids" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$issue_count" -ne 1 ]; then
    bad "ticket ownership unknown after helper failure (expected one exact marker/project issue, found $issue_count)"
    LIVE_OWNERSHIP_UNKNOWN=1
    return 1
  fi
  issue_id="$(printf '%s\n' "$issue_ids" | sed '/^$/d')"
  LIVE_PROJECT_ISSUE_IDS="$LIVE_PROJECT_ISSUE_IDS $issue_id"
  ok "recover exactly one ticket ownership record after helper failure"
  return 0
}
create_process_agent() {
  local key="$1" project="$2" workspace="$3" payload id name
  name="workspace-routing-process-$key-$$"
  payload="$(jq -nc --arg n "$name" \
    --arg cmd "$adapter_script" --arg record "$LIVE_RECORD" --arg release "$LIVE_RELEASE" \
    --arg key "$key" --arg project "$project" --arg workspace "$workspace" \
    '{name:$n,role:"general",adapterType:"process",
      adapterConfig:{command:$cmd,args:[$key,$project,$workspace,$record,$release],timeoutSec:120},
      runtimeConfig:{heartbeat:{maxConcurrentRuns:3}},
      metadata:{opcWorkspaceRoutingTest:true}}')"
  live_mutation POST "/companies/$LIVE_COMPANY_ID/agents" "$payload" || return 1
  id="$(printf '%s' "$LIVE_RESPONSE_BODY" | jq -r '.id // empty')"
  if [ -z "$id" ]; then
    id="$(live_api GET "/companies/$LIVE_COMPANY_ID/agents" 2>/dev/null \
      | jq -r --arg n "$name" '.[] | select(.name == $n and .metadata.opcWorkspaceRoutingTest == true) | .id' \
      | head -n 1)"
    [ -n "$id" ] && LIVE_TEST_AGENT_IDS="$LIVE_TEST_AGENT_IDS $id"
    return 1
  fi
  LIVE_TEST_AGENT_IDS="$LIVE_TEST_AGENT_IDS $id"
  LIVE_CREATED_AGENT_ID="$id"
}
live_wait_for() {
  local label="$1" command="$2"
  for _ in $(seq 1 60); do
    if eval "$command"; then ok "$label"; return 0; fi
    sleep 1
  done
  bad "$label (timed out)"
  return 1
}
live_restore() {
  [ "$LIVE_RESTORE_NEEDED" -eq 1 ] || return 0
  local payload saved live
  saved="$(cat "$LIVE_ORIGINAL_AGENT")" || {
    bad "restore original engineer objects (saved object unreadable)"
    return 1
  }
  payload="$(jq -c '{runtimeConfig,metadata}' "$LIVE_ORIGINAL_AGENT")" || {
    bad "restore original engineer objects (saved object invalid)"
    return 1
  }
  if ! live_mutation PATCH "/agents/$LIVE_AGENT_ID" "$payload"; then
    bad "restore exact original engineer runtimeConfig and metadata (HTTP $LIVE_RESPONSE_STATUS)"
    return 1
  fi
  live="$(live_api GET "/agents/$LIVE_AGENT_ID" 2>/dev/null || true)"
  if [ "$(printf '%s' "$live" | jq -c '{runtimeConfig,metadata}' 2>/dev/null)" != "$saved" ]; then
    bad "restore exact original engineer runtimeConfig and metadata (GET mismatch)"
    return 1
  fi
  LIVE_RESTORE_NEEDED=0
  ok "restore exact original engineer runtimeConfig and metadata"
}
cancel_test_issues_for_cleanup() {
  local issue issue_status cleanup_ok=1 cancel_settled
  for issue in $LIVE_PROJECT_ISSUE_IDS; do
    if ! live_mutation GET "/issues/$issue"; then
      case "$LIVE_RESPONSE_STATUS" in
        404) ok "test issue $issue already absent before workspace cleanup" ;;
        *) bad "inspect test issue $issue before workspace cleanup (HTTP $LIVE_RESPONSE_STATUS)"; cleanup_ok=0 ;;
      esac
      continue
    fi
    issue_status="$(printf '%s' "$LIVE_RESPONSE_BODY" | jq -r '.status // empty')"
    case "$issue_status" in
      done|cancelled)
        ok "test issue $issue is already terminal"
        ;;
      *)
        if ! live_mutation PATCH "/issues/$issue" '{"status":"cancelled"}'; then
          bad "cancel test issue $issue before workspace cleanup (HTTP $LIVE_RESPONSE_STATUS)"
          cleanup_ok=0
          continue
        fi
        # Poll instead of reading once, and re-issue the cancel each round.
        # The test's own agent runs are still draining at teardown, and one of
        # them can move the issue back off `cancelled` (observed: OPC-113 ended
        # `blocked` moments after a successful cancel). A single read races that
        # and reports a cancel failure that is really a timing artifact — the
        # same PATCH succeeds seconds later. This is a settle-wait, not a retry
        # of a broken call: it stops as soon as the status holds.
        cancel_settled=0
        for _ in 1 2 3 4 5 6 7 8 9 10; do
          if live_mutation GET "/issues/$issue" &&
            [ "$(printf '%s' "$LIVE_RESPONSE_BODY" | jq -r '.status // empty')" = cancelled ]; then
            cancel_settled=1
            break
          fi
          sleep 2
          live_mutation PATCH "/issues/$issue" '{"status":"cancelled"}' || true
        done
        if [ "$cancel_settled" -eq 1 ]; then
          ok "cancel test issue $issue before workspace cleanup"
        else
          bad "verify test issue $issue cancelled before workspace cleanup (still $(printf '%s' "$LIVE_RESPONSE_BODY" | jq -r '.status // "unknown"') after 10 attempts)"
          cleanup_ok=0
        fi
        ;;
    esac
  done
  [ "$cleanup_ok" -eq 1 ]
}
delete_test_issue_comments() {
  local issue comments comment_ids comment_id cleanup_status=1 cleanup_agent \
    cleanup_key cleanup_key_id key_name comment_deleted system_comment_count residual
  for issue in $LIVE_PROJECT_ISSUE_IDS; do
    if ! live_mutation GET "/issues/$issue/comments"; then
      bad "list comments for test issue $issue (HTTP $LIVE_RESPONSE_STATUS)"
      cleanup_status=0
      continue
    fi
    comments="$LIVE_RESPONSE_BODY"
    if ! printf '%s' "$comments" | jq -e '
      type == "array"
      and all(.[]; type == "object" and (.id | type == "string" and length > 0))
    ' >/dev/null 2>&1; then
      bad "list comments for test issue $issue (response is not a valid array)"
      cleanup_status=0
      continue
    fi
    # Paperclip injects its own comments onto these issues while the test runs
    # — the disposition watchdog files an `authorType: "system"` notice
    # ("Paperclip needs a disposition before this issue can continue") on any
    # issue whose run finished without one. Those have NO author_agent_id and
    # NO author_user_id, so no agent key can own them and the loop below cannot
    # delete them by design. Counting them as cleanup failures blocked teardown
    # and left test prototypes and projects behind on the live stack.
    #
    # They are Paperclip's rows, not the test's, and they go away with the issue.
    # Skip them; still delete (and still assert on) every agent-authored comment.
    system_comment_count="$(printf '%s' "$comments" | \
      jq -r '[.[] | select(.authorType == "system")] | length')"
    if [ "${system_comment_count:-0}" != 0 ]; then
      ok "test issue $issue: $system_comment_count Paperclip system comment(s) left to the issue"
    fi
    comment_ids="$(printf '%s' "$comments" | \
      jq -r '.[] | select(.authorType != "system") | .id')"
    while IFS= read -r comment_id; do
      [ -n "$comment_id" ] || continue
      comment_deleted=0
      for cleanup_agent in $LIVE_TEST_AGENT_IDS $LIVE_AGENT_ID; do
        key_name="opc-workspace-routing-cleanup-$issue-$comment_id-$$"
        cleanup_key=""
        cleanup_key_id=""
        if live_mutation POST "/agents/$cleanup_agent/keys" \
          "$(jq -nc --arg n "$key_name" '{name:$n}')"; then
          cleanup_key="$(printf '%s' "$LIVE_RESPONSE_BODY" | jq -r '.token // empty')"
          cleanup_key_id="$(printf '%s' "$LIVE_RESPONSE_BODY" | jq -r '.id // empty')"
        fi
        if [ -n "$cleanup_key" ] && [ -n "$cleanup_key_id" ]; then
          if live_key_mutation "$cleanup_key" DELETE "/issues/$issue/comments/$comment_id"; then
            comment_deleted=1
          fi
          if ! live_mutation DELETE "/agents/$cleanup_agent/keys/$cleanup_key_id"; then
            bad "revoke temporary comment-cleanup key for test agent $cleanup_agent (HTTP $LIVE_RESPONSE_STATUS)"
            cleanup_status=0
          fi
        elif [ -n "$cleanup_key_id" ]; then
          live_mutation DELETE "/agents/$cleanup_agent/keys/$cleanup_key_id" || true
        fi
        [ "$comment_deleted" -eq 1 ] && break
      done
      if [ "$comment_deleted" -eq 1 ]; then
        ok "test issue comment $comment_id cleanup"
      else
        bad "test issue comment $comment_id delete (no owning test-agent key accepted)"
        cleanup_status=0
      fi
    done <<EOF
$comment_ids
EOF
    # Counts AGENT-authored comments, not all of them. The loop above
    # deliberately leaves Paperclip's own `authorType: "system"` notices — they
    # have no owning agent, so no agent key can delete them — and asserting an
    # empty list here would fail for rows the test never created and cannot
    # remove. They go away with the issue.
    #
    # Polled, because the list endpoint lags its own DELETE. The discriminator
    # was exact: issues where nothing was deleted passed on the first read,
    # while every issue that had just had a comment deleted failed here — and
    # the same GET returned 0 moments later. A single read measures replication
    # timing, not cleanup.
    residual=-1
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if live_mutation GET "/issues/$issue/comments"; then
        residual="$(printf '%s' "$LIVE_RESPONSE_BODY" | jq -r '
          if type == "array"
          then [.[] | select(.authorType != "system")] | length
          else -1 end')"
        [ "$residual" = 0 ] && break
      fi
      sleep 1
    done
    if [ "$residual" = 0 ]; then
      ok "verify test issue comments removed $issue"
    else
      bad "verify test issue comments removed $issue ($residual agent-authored comment(s) still listed after 10s; last HTTP $LIVE_RESPONSE_STATUS)"
      cleanup_status=0
    fi
  done
  [ "$cleanup_status" -eq 1 ]
}


archive_test_execution_workspaces() {
  local project_id="$1" workspaces workspace_ids workspace_id workspace_status \
    verify_status remaining test_issue_ids archive_ok=1 workspace_ok attempt
  [ -n "$project_id" ] || return 0
  if ! live_mutation GET "/companies/$LIVE_COMPANY_ID/execution-workspaces?projectId=$project_id"; then
    bad "list test execution workspaces for project $project_id (HTTP $LIVE_RESPONSE_STATUS)"
    return 1
  fi
  workspaces="$LIVE_RESPONSE_BODY"
  if ! printf '%s' "$workspaces" | jq -e 'type == "array"' >/dev/null 2>&1; then
    bad "list test execution workspaces for project $project_id (response is not an array)"
    return 1
  fi
  test_issue_ids="$LIVE_PROJECT_ISSUE_IDS"
  workspace_ids="$(printf '%s' "$workspaces" | jq -r --arg project "$project_id" --arg ids "$test_issue_ids" \
    '.[] as $workspace | select($workspace.projectId == $project
      and $workspace.strategyType == "git_worktree"
      and (($ids | split(" ")) | index($workspace.sourceIssueId)) != null) | $workspace.id // empty')"
  for workspace_id in $workspace_ids; do
    workspace_status="$(printf '%s' "$workspaces" | jq -r --arg id "$workspace_id" \
      '.[] | select(.id == $id) | .status // empty')"
    if [ "$workspace_status" = archived ]; then
      ok "test execution workspace $workspace_id already archived"
      continue
    fi
    attempt=1
    workspace_ok=1
    while :; do
      if live_mutation PATCH "/execution-workspaces/$workspace_id" '{"status":"archived"}'; then
        break
      fi
      if [ "$LIVE_RESPONSE_STATUS" = 409 ] && [ "$attempt" -lt 30 ]; then
        attempt=$((attempt + 1))
        sleep 1
        continue
      fi
      bad "archive test execution workspace $workspace_id (HTTP $LIVE_RESPONSE_STATUS)"
      workspace_ok=0
      archive_ok=0
      break
    done
    [ "$workspace_ok" -eq 1 ] || continue
    if live_mutation GET "/execution-workspaces/$workspace_id"; then
      verify_status="$(printf '%s' "$LIVE_RESPONSE_BODY" | jq -r '.status // empty')"
      if [ "$verify_status" = archived ]; then
        ok "archive test execution workspace $workspace_id"
      else
        bad "archive test execution workspace $workspace_id (status=$verify_status)"
        workspace_ok=0
        archive_ok=0
      fi
    else
      case "$LIVE_RESPONSE_STATUS" in
        404) ok "archive test execution workspace $workspace_id (absent)" ;;
        *) bad "archive test execution workspace $workspace_id verification (HTTP $LIVE_RESPONSE_STATUS)"; workspace_ok=0; archive_ok=0 ;;
      esac
    fi
  done
  if ! live_mutation GET "/companies/$LIVE_COMPANY_ID/execution-workspaces?projectId=$project_id"; then
    bad "verify test execution workspaces for project $project_id (HTTP $LIVE_RESPONSE_STATUS)"
    return 1
  fi
  remaining="$(printf '%s' "$LIVE_RESPONSE_BODY" | jq -r --arg ids "$test_issue_ids" \
    '[.[] as $workspace | select($workspace.status != "archived"
      and $workspace.strategyType == "git_worktree"
      and (($ids | split(" ")) | index($workspace.sourceIssueId)) != null)] | length' \
    2>/dev/null || printf 'invalid')"
  if [ "$remaining" = 0 ] && [ "$archive_ok" -eq 1 ]; then
    ok "verify test execution workspaces archived for project $project_id"
    return 0
  fi
  bad "verify test execution workspaces archived for project $project_id (active=$remaining)"
  return 1
}


live_cleanup() {
  local issue name agent project_id cleanup_status=0 gone live_runs drain_ok=1 \
    holder_present=0 workspace_cleanup_ok=1 issue_cleanup_ok=1 prototype_cleanup_ok=1
  if [ -n "${LIVE_ADAPTER_SCRIPT:-}" ]; then
    if ! docker compose exec -T paperclip sh -c "touch '$LIVE_RELEASE'"; then
      bad "release process probe holders"
      cleanup_status=1
      drain_ok=0
    else
      for _ in $(seq 1 30); do
        if ! live_mutation GET "/companies/$LIVE_COMPANY_ID/live-runs?minCount=0&limit=1000"; then
          bad "inspect process holder runs during cleanup (HTTP $LIVE_RESPONSE_STATUS)"
          cleanup_status=1
          drain_ok=0
          break
        fi
        live_runs="$LIVE_RESPONSE_BODY"
        if printf '%s' "$live_runs" | jq -e --arg ids "$LIVE_TEST_AGENT_IDS" \
          'any(.[]? as $run; ($run.status == "queued" or $run.status == "running")
            and (($ids | split(" ")) | index($run.agentId)) != null)' >/dev/null 2>&1; then
          holder_present=1
          sleep 1
        else
          holder_present=0
          break
        fi
      done
      if [ "$holder_present" -eq 1 ]; then
        bad "process holder runs drained before cleanup"
        cleanup_status=1
        drain_ok=0
      fi
    fi
  fi
  live_restore || cleanup_status=1
  restore_preexisting_project || cleanup_status=1
  if [ "${OPC_WORKSPACE_ROUTING_EPHEMERAL:-0}" = 1 ]; then
    echo "INFO  ephemeral routing gate: enclosing fresh-install teardown owns test record cleanup"
  elif [ "$LIVE_OWNERSHIP_UNKNOWN" -eq 1 ]; then
    echo "BLOCKER leaving test agents/issues/projects because ticket ownership is unknown"
    cleanup_status=1
  elif [ "$drain_ok" -eq 1 ]; then
    if ! cancel_test_issues_for_cleanup; then
      cleanup_status=1
      workspace_cleanup_ok=0
    else
      for project_id in $LIVE_TEST_PROJECT_IDS; do
        archive_test_execution_workspaces "$project_id" || {
          cleanup_status=1
          workspace_cleanup_ok=0
        }
      done
      if [ "$workspace_cleanup_ok" -eq 1 ]; then
        if ! delete_test_issue_comments; then
          cleanup_status=1
          issue_cleanup_ok=0
        else
          for issue in $LIVE_PROJECT_ISSUE_IDS; do
            delete_and_verify "test issue $issue" "/issues/$issue" "/issues/$issue" absent || {
              cleanup_status=1
              issue_cleanup_ok=0
            }
          done
        fi
        if [ "$issue_cleanup_ok" -eq 1 ]; then
          for name in $LIVE_PROTO_NAMES; do
            if ! printf '%s\n' "$name" | docker compose exec -T paperclip prototype destroy "$name" >/dev/null 2>&1; then
              bad "test prototype $name cleanup"
              cleanup_status=1
              prototype_cleanup_ok=0
            else
              gone=0
              for _ in $(seq 1 10); do
                if ! live_mutation GET "/companies/$LIVE_COMPANY_ID/projects"; then
                  case "$LIVE_RESPONSE_STATUS" in
                    404) gone=1; break ;;
                    *) bad "test prototype $name cleanup verification (HTTP $LIVE_RESPONSE_STATUS)"; cleanup_status=1; break ;;
                  esac
                elif ! printf '%s' "$LIVE_RESPONSE_BODY" | jq -e --arg n "$name" 'any(.[]; .name == $n)' >/dev/null 2>&1; then
                  gone=1
                  break
                fi
                sleep 1
              done
              if [ "$gone" -eq 1 ]; then
                ok "test prototype $name cleanup"
              else
                bad "test prototype $name cleanup verification"
                cleanup_status=1
                prototype_cleanup_ok=0
              fi
            fi
          done
        else
          echo "BLOCKER leaving test prototypes because issue cleanup was not proven"
        fi
      else
        echo "BLOCKER leaving test prototypes because execution workspaces were not archived"
      fi
      if [ "$workspace_cleanup_ok" -eq 1 ] &&
         [ "$issue_cleanup_ok" -eq 1 ] &&
         [ "$prototype_cleanup_ok" -eq 1 ]; then
        if [ -n "$LIVE_PROJECT_ID" ] &&
           [ "$LIVE_PROJECT_PREEXISTING" -eq 0 ] &&
           [ "$LIVE_PROJECT_ID" != "$LIVE_PREEXISTING_PROJECT_ID" ]; then
          delete_and_verify "test engineering project $LIVE_PROJECT_ID" \
            "/projects/$LIVE_PROJECT_ID" "/projects/$LIVE_PROJECT_ID" absent || cleanup_status=1
        elif [ "$LIVE_PROJECT_PREEXISTING" -eq 1 ] &&
             [ -n "$LIVE_PREEXISTING_PROJECT_ID" ] &&
             [ "$LIVE_PROJECT_ID" = "$LIVE_PREEXISTING_PROJECT_ID" ]; then
          if live_mutation GET "/projects/$LIVE_PREEXISTING_PROJECT_ID"; then
            ok "preserve pre-existing engineering project $LIVE_PREEXISTING_PROJECT_ID"
          else
            bad "preserve pre-existing engineering project $LIVE_PREEXISTING_PROJECT_ID (HTTP $LIVE_RESPONSE_STATUS)"
            cleanup_status=1
          fi
        elif [ -n "$LIVE_PROJECT_ID" ]; then
          bad "refusing to classify routed project ownership during cleanup"
          cleanup_status=1
        fi
      elif [ "$workspace_cleanup_ok" -ne 1 ]; then
        echo "BLOCKER leaving test issues/projects because execution workspaces were not archived"
      elif [ "$issue_cleanup_ok" -ne 1 ]; then
        echo "BLOCKER leaving test prototypes/projects because issue cleanup was not proven"
      else
        echo "BLOCKER leaving test engineering project because test prototypes were not destroyed"
      fi
    fi
    for agent in $LIVE_TEST_AGENT_IDS; do
      delete_and_verify "test process agent $agent" "/agents/$agent" "/agents/$agent" absent || cleanup_status=1
    done
  else
    echo "BLOCKER leaving test agents/issues/project because holder quiescence was not proven"
  fi
  if ! docker compose exec -T paperclip sh -c "rm -f '$LIVE_RECORD' '$LIVE_RELEASE' '$LIVE_ADAPTER_SCRIPT'"; then
    bad "remove container process probe files"
    cleanup_status=1
  fi
  rm -f "$LIVE_RECORD" "$LIVE_RELEASE"
  rm -rf "$LIVE_TMPDIR"
  LIVE_CLEANUP_STATUS="$cleanup_status"
  return "$cleanup_status"
}

live_gate() {
  local company agents engineer marker current experimental repo repo_path repo_owner repo_name \
    preexisting_project preexisting_project_id preexisting_project_status preexisting_project_error preexisting_project_error_text \
    ticket second project workspace project_json workspace_show prototype project_id workspace_id \
    test_agent issue_a issue_b issue_c run_json marker_source issue_json fail_before
  fail_before="$FAIL"
  LIVE_PROJECT_PREEXISTING=0
  LIVE_PREEXISTING_PROJECT_ID=""
  LIVE_PROJECT_ID=""
  LIVE_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/opc-workspace-routing-live.XXXXXX")"
  chmod 700 "$LIVE_TMPDIR"
  LIVE_ORIGINAL_AGENT="$LIVE_TMPDIR/original-agent.json"
  LIVE_PREEXISTING_SNAPSHOT="$LIVE_TMPDIR/preexisting-project.json"
  : >"$LIVE_PREEXISTING_SNAPSHOT"
  chmod 600 "$LIVE_PREEXISTING_SNAPSHOT"
  LIVE_PREEXISTING_RESTORE_NEEDED=0
  LIVE_OWNERSHIP_UNKNOWN=0
  : >"$LIVE_ORIGINAL_AGENT"
  chmod 600 "$LIVE_ORIGINAL_AGENT"
  LIVE_RECORD="$LIVE_TMPDIR/execution-paths"
  LIVE_RELEASE="$LIVE_TMPDIR/release"
  : >"$LIVE_RECORD"
  : >"$LIVE_RELEASE"
  LIVE_MARKER="opc-workspace-routing-$RANDOM-$(date +%s)-$$"
  trap live_cleanup EXIT INT TERM
  LIVE_BASE="http://127.0.0.1:${PAPERCLIP_PORT:-3100}/api"
  LIVE_BOARD_KEY="$(docker compose exec -T paperclip sh -c 'cat /paperclip/.opc/board-api.key' | tr -d '\r\n')" || {
    bad "obtain Paperclip board key inside container"
    return 1
  }
  [ -n "$LIVE_BOARD_KEY" ] || { bad "obtain Paperclip board key inside container"; return 1; }
  ok "obtain Paperclip board key inside container"
  export PAPERCLIP_API_URL="http://127.0.0.1:${PAPERCLIP_PORT:-3100}"
  export PAPERCLIP_API_KEY="$LIVE_BOARD_KEY"

  experimental="$(live_api GET /instance/settings/experimental)" || {
    bad "experimental settings endpoint responds"
    return 1
  }
  assert_eq "live isolated workspaces enabled" true \
    "$(printf '%s' "$experimental" | jq -r '.enableIsolatedWorkspaces // false')"
  company="$(live_api GET /companies | jq -c 'if length == 1 then .[0] else empty end')" || {
    bad "resolve exactly one Paperclip company"
    return 1
  }
  LIVE_COMPANY_ID="$(printf '%s' "$company" | jq -r '.id')"
  agents="$(live_api GET "/companies/$LIVE_COMPANY_ID/agents")" || {
    return 1
  }
  engineer="$(printf '%s' "$agents" | jq -c '[.[] | select(.role == "engineer")] | if length == 1 then .[0] else empty end')"
  [ -n "$engineer" ] || {
    bad "resolve exactly one live engineer agent"
    return 1
  }
  LIVE_AGENT_ID="$(printf '%s' "$engineer" | jq -r '.id')"
  printf '%s' "$engineer" | jq -c '{runtimeConfig,metadata}' >"$LIVE_ORIGINAL_AGENT"
  LIVE_RESTORE_NEEDED=1
  marker="$(printf '%s' "$engineer" | jq -r '.metadata.opcManagedDefaults.fullstackMaxConcurrentRuns // empty')"
  current="$(printf '%s' "$engineer" | jq -r '.runtimeConfig.heartbeat.maxConcurrentRuns // empty')"
  if [ "$marker" = 4 ]; then
    assert_eq "managed engineer default is four runs" 4 "$current"
    marker_source=managed_default
  else
    echo "INFO  preserving existing operator concurrency override (marker=${marker:-absent}, max=${current:-absent})"
    marker_source=operator_override
  fi
  ok "live engineer agent has source=$marker_source"
  if "$CLI" agent concurrency set --role engineer --max 6 >/dev/null; then
    assert_eq "live operator concurrency set to six" 6 \
      "$("$CLI" agent concurrency show --role engineer | jq -r .maxConcurrentRuns)"
  else
    bad "live operator concurrency set to six"
  fi
  if docker compose up --force-recreate paperclip-bootstrap >/dev/null; then
    assert_eq "six-run override survives bootstrap recreate" 6 \
      "$("$CLI" agent concurrency show --role engineer | jq -r .maxConcurrentRuns)"
  else
    bad "paperclip-bootstrap force-recreate"
  fi
  if "$CLI" agent concurrency reset --role engineer >/dev/null; then
    assert_eq "live concurrency reset returns four" 4 \
      "$("$CLI" agent concurrency show --role engineer | jq -r .maxConcurrentRuns)"
  else
    bad "live concurrency reset"
  fi

  repo="${PAPERCLIP_WORKSPACE_TEST_REPO_URL:-https://github.com/XuHaoJun/opc-stack.git}"
  repo_path="${repo#*github.com/}"
  [ "$repo_path" = "$repo" ] && repo_path="${repo#*github.com:}"
  repo_path="${repo_path%/}"
  repo_owner="${repo_path%%/*}"
  repo_name="${repo_path#*/}"
  repo_name="${repo_name%.git}"
  if [ -n "$repo_owner" ] && [ -n "$repo_name" ] && [ "$repo_name" != "$repo_path" ]; then
    second="https://github.com/${repo_owner^^}/${repo_name}.git"
  else
    second="$repo"
  fi
  preexisting_project_error="$LIVE_TMPDIR/preexisting-project.err"
  if preexisting_project="$("$CLI" project workspace show --repo "$repo" 2>"$preexisting_project_error")"; then
    if ! preexisting_project_id="$(printf '%s' "$preexisting_project" | jq -er '
      if (type != "object") or (.project.id | type != "string") or (.workspace.id | type != "string")
      then error("invalid project workspace response")
      else .project.id
      end' 2>/dev/null)"; then
      bad "resolve whether engineering project is pre-existing (malformed CLI response)"
      return 1
    fi
    LIVE_PREEXISTING_PROJECT_ID="$preexisting_project_id"
    snapshot_preexisting_project "$preexisting_project_id" || return 1
    echo "INFO  preserving pre-existing engineering project $LIVE_PREEXISTING_PROJECT_ID"
  else
    preexisting_project_status=$?
    preexisting_project_error_text="$(cat "$preexisting_project_error")"
    case "$preexisting_project_error_text" in
      *"no Paperclip project matches"*) preexisting_project_id="" ;;
      *) bad "resolve whether engineering project is pre-existing (CLI status=$preexisting_project_status)"; return 1 ;;
    esac
  fi
  if ! ticket="$(printf '%s\n' "$LIVE_MARKER engineering backlog fixture" | "$CLI" engineering-ticket create \
    --repo "$repo" --title "$LIVE_MARKER workspace routing fixture" --status backlog)"; then
    recover_live_ticket_ownership "$repo" "$LIVE_MARKER engineering backlog fixture"$'\n' || true
    bad "create test-owned backlog engineering ticket (ownership recovery attempted)"
    [ "$LIVE_OWNERSHIP_UNKNOWN" -eq 1 ] && echo "BLOCKER ticket ownership unknown after helper failure"
    return 1
  fi
  LIVE_PROJECT_ID="$(printf '%s' "$ticket" | jq -r '.projectId // empty')"
  if [ -n "$LIVE_PREEXISTING_PROJECT_ID" ] && [ "$LIVE_PREEXISTING_PROJECT_ID" = "$LIVE_PROJECT_ID" ]; then
    LIVE_PROJECT_PREEXISTING=1
    echo "INFO  preserving pre-existing engineering project $LIVE_PREEXISTING_PROJECT_ID"
  else
    LIVE_PROJECT_PREEXISTING=0
  fi
  issue_a="$(printf '%s' "$ticket" | jq -r '.id // empty')"
  workspace_id="$(printf '%s' "$ticket" | jq -r '.projectWorkspaceId // empty')"
  [ -n "$LIVE_PROJECT_ID" ] && [ -n "$issue_a" ] && [ -n "$workspace_id" ] || {
    bad "engineering ticket binds project and primary workspace"
    return 1
  }
  LIVE_PROJECT_ISSUE_IDS="$issue_a"
  LIVE_TEST_PROJECT_IDS="$LIVE_PROJECT_ID"
  project_json="$(live_api GET "/projects/$LIVE_PROJECT_ID")"
  assert_eq "engineering project has one primary git workspace" 1 \
    "$(printf '%s' "$project_json" | jq '(.workspaces // []) | map(select(.isPrimary == true and .sourceType == "git_repo")) | length')"
  assert_eq "engineering project uses isolated worktrees" isolated_workspace \
    "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.defaultMode')"
  assert_eq "engineering project uses git worktrees" git_worktree \
    "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.workspaceStrategy.type')"
  issue_json="$(live_api GET "/issues/$issue_a")"
  assert_eq "backlog ticket binds project" "$LIVE_PROJECT_ID" \
    "$(printf '%s' "$issue_json" | jq -r '.projectId')"
  assert_eq "backlog ticket binds primary workspace" "$workspace_id" \
    "$(printf '%s' "$issue_json" | jq -r '.projectWorkspaceId')"
  assert_eq "backlog ticket inherits project policy" inherit \
    "$(printf '%s' "$issue_json" | jq -r '.executionWorkspaceSettings.mode // .executionWorkspacePreference // empty')"
  if ! ticket="$(printf '%s\n' "$LIVE_MARKER engineering second backlog fixture" | "$CLI" engineering-ticket create \
    --repo "$second" --title "$LIVE_MARKER workspace routing fixture second" --status backlog)"; then
    recover_live_ticket_ownership "$second" "$LIVE_MARKER engineering second backlog fixture"$'\n' || true
    bad "create second-form engineering ticket (ownership recovery attempted)"
    [ "$LIVE_OWNERSHIP_UNKNOWN" -eq 1 ] && echo "BLOCKER second ticket ownership unknown after helper failure"
    return 1
  fi
  issue_second="$(printf '%s' "$ticket" | jq -r '.id // empty')"
  [ -n "$issue_second" ] || { bad "create second-form engineering ticket response"; return 1; }
  LIVE_PROJECT_ISSUE_IDS="$LIVE_PROJECT_ISSUE_IDS $issue_second"
  workspace_show="$("$CLI" project workspace show --repo "$repo")"
  assert_eq "workspace show reports managed default source" managed_default \
    "$(printf '%s' "$workspace_show" | jq -r '.source')"
  assert_eq "workspace show reports isolated git-worktree default" isolated_workspace \
    "$(printf '%s' "$workspace_show" | jq -r '.policy.mode')"

  prototype="wsroute-proto-$(date +%s)-$$"
  LIVE_PROTO_NAMES="$prototype"
  if docker compose exec -T paperclip prototype create "$prototype" --idle never >/dev/null; then
    ok "prototype create test prototype"
  else
    bad "prototype create test prototype"
    return 1
  fi
  if docker compose exec -T paperclip prototype create "$prototype" --idle never >/dev/null; then
    ok "prototype resume test prototype"
  else
    bad "prototype resume test prototype"
    return 1
  fi
  prototype_id="$(live_api GET "/companies/$LIVE_COMPANY_ID/projects" | jq -r --arg n "$prototype" '[.[] | select(.name == $n)] | if length == 1 then .[0].id else empty end')"
  [ -n "$prototype_id" ] || { bad "prototype create/resume persists one project"; return 1; }
  LIVE_TEST_PROJECT_IDS="$LIVE_TEST_PROJECT_IDS $prototype_id"
  project_json="$(live_api GET "/projects/$prototype_id")"
  assert_eq "prototype policy is shared" shared_workspace \
    "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.defaultMode')"
  assert_eq "prototype policy serializes" serialize \
    "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.sharedWorkspaceConcurrency')"
  assert_eq "prototype policy uses project primary" project_primary \
    "$(printf '%s' "$project_json" | jq -r '.executionWorkspacePolicy.workspaceStrategy.type')"
  adapter_script="/tmp/opc-workspace-routing-agent-$$.sh"
  LIVE_ADAPTER_SCRIPT="$adapter_script"
  LIVE_RECORD="/tmp/opc-workspace-routing-paths-$$"
  LIVE_RELEASE="/tmp/opc-workspace-routing-release-$$"
  docker compose exec -T paperclip sh -c "rm -f '$LIVE_RECORD' '$LIVE_RELEASE' '$adapter_script'"
  cat <<'AGENT_SCRIPT' | docker compose exec -T paperclip sh -c "cat > '$adapter_script' && chmod 755 '$adapter_script'"
#!/bin/sh
issue_key="${1:?missing issue key}"
project_id="${2:?missing project id}"
workspace_id="${3:?missing workspace id}"
record="${4:?missing record path}"
release="${5:?missing release path}"
printf '%s\t%s\t%s\t%s\n' "$issue_key" "$project_id" "$workspace_id" "$(pwd)" >> "$record"
while [ ! -e "$release" ]; do sleep 0.2; done
AGENT_SCRIPT
  create_process_agent engineering-a "$LIVE_PROJECT_ID" "$workspace_id" || { bad "create test-owned process adapter agent A"; return 1; }
  test_agent_a="$LIVE_CREATED_AGENT_ID"
  create_process_agent engineering-b "$LIVE_PROJECT_ID" "$workspace_id" || { bad "create test-owned process adapter agent B"; return 1; }
  test_agent_b="$LIVE_CREATED_AGENT_ID"
  issue_payload="$(jq -nc --arg p "$LIVE_PROJECT_ID" --arg w "$workspace_id" --arg a "$test_agent_a" --arg marker "$LIVE_MARKER" \
    '{title:"workspace routing execution A",description:($marker+" execution A"),
      status:"todo",projectId:$p,projectWorkspaceId:$w,assigneeAgentId:$a,
      executionWorkspaceSettings:{mode:"inherit"}}')"
  create_issue "$issue_payload" || { bad "create execution issue A"; return 1; }
  issue_a="$LIVE_CREATED_ISSUE_ID"
  issue_payload="$(jq -nc --arg p "$LIVE_PROJECT_ID" --arg w "$workspace_id" --arg a "$test_agent_b" --arg marker "$LIVE_MARKER" \
    '{title:"workspace routing execution B",description:($marker+" execution B"),
      status:"todo",projectId:$p,projectWorkspaceId:$w,assigneeAgentId:$a,
      executionWorkspaceSettings:{mode:"inherit"}}')"
  create_issue "$issue_payload" || { bad "create execution issue B"; return 1; }
  issue_b="$LIVE_CREATED_ISSUE_ID"
  LIVE_PROJECT_ISSUE_IDS="$LIVE_PROJECT_ISSUE_IDS $issue_a $issue_b"
  wake_issue "$test_agent_a" "$issue_a" || return 1
  wake_issue "$test_agent_b" "$issue_b" || return 1
  paths=""
  for _ in $(seq 1 60); do
    paths="$(docker compose exec -T paperclip sh -c "cat '$LIVE_RECORD' 2>/dev/null || true")"
    [ "$(printf '%s\n' "$paths" | sed '/^$/d' | wc -l | tr -d ' ')" -ge 2 ] && break
    sleep 1
  done
  if [ "$(printf '%s\n' "$paths" | sed '/^$/d' | wc -l | tr -d ' ')" -ge 2 ]; then
    workspaces_a="$(live_api GET "/companies/$LIVE_COMPANY_ID/execution-workspaces?issueId=$issue_a" 2>/dev/null || true)"
    workspaces_b="$(live_api GET "/companies/$LIVE_COMPANY_ID/execution-workspaces?issueId=$issue_b" 2>/dev/null || true)"
    workspace_a="$(printf '%s' "$workspaces_a" | jq -c 'if type == "array" then .[0] else . end' 2>/dev/null || true)"
    workspace_b="$(printf '%s' "$workspaces_b" | jq -c 'if type == "array" then .[0] else . end' 2>/dev/null || true)"
    path_a="$(printf '%s' "$workspace_a" | jq -r '.cwd // .providerRef // empty')"
    path_b="$(printf '%s' "$workspace_b" | jq -r '.cwd // .providerRef // empty')"
    strategy_a="$(printf '%s' "$workspace_a" | jq -r '.strategyType // .workspaceStrategy.type // empty')"
    strategy_b="$(printf '%s' "$workspace_b" | jq -r '.strategyType // .workspaceStrategy.type // empty')"
    [ "$(printf '%s' "$workspace_a" | jq -r '.projectWorkspaceId // empty')" = "$workspace_id" ] \
      && [ "$(printf '%s' "$workspace_b" | jq -r '.projectWorkspaceId // empty')" = "$workspace_id" ] \
      && ok "execution workspaces bind project primary" \
      || bad "execution workspaces bind project primary"
    [ "$strategy_a" = git_worktree ] && [ "$strategy_b" = git_worktree ] \
      && [ -n "$path_a" ] && [ -n "$path_b" ] && [ "$path_a" != "$path_b" ] \
      && ok "engineering runs report distinct managed git worktrees" \
      || bad "engineering runs report distinct managed git worktrees"
    worktree_a_ok=0
    worktree_b_ok=0
    if docker compose exec -T paperclip test -d "$path_a" \
      && docker compose exec -T paperclip git -c safe.directory="$path_a" -C "$path_a" rev-parse --git-dir >/dev/null 2>&1; then
      worktree_a_ok=1
    fi
    if docker compose exec -T paperclip test -d "$path_b" \
      && docker compose exec -T paperclip git -c safe.directory="$path_b" -C "$path_b" rev-parse --git-dir >/dev/null 2>&1; then
      worktree_b_ok=1
    fi
    if [ "$worktree_a_ok" -eq 1 ] && [ "$worktree_b_ok" -eq 1 ]; then
      ok "execution workspace paths are real Git worktrees"
    else
      echo "INFO  worktree A path: $path_a"
      if docker compose exec -T paperclip test -d "$path_a"; then
        echo "INFO  worktree A directory exists"
      else
        echo "INFO  worktree A directory missing"
      fi
      docker compose exec -T paperclip git -c safe.directory="$path_a" -C "$path_a" rev-parse --git-dir 2>&1 \
        | sed -n '1,5p' || true
      echo "INFO  worktree B path: $path_b"
      if docker compose exec -T paperclip test -d "$path_b"; then
        echo "INFO  worktree B directory exists"
      else
        echo "INFO  worktree B directory missing"
      fi
      docker compose exec -T paperclip git -c safe.directory="$path_b" -C "$path_b" rev-parse --git-dir 2>&1 \
        | sed -n '1,5p' || true
      bad "execution workspace paths are real Git worktrees"
    fi
  else
    echo "BLOCKER process adapter produced no workspace records; live run state follows:"
    live_api GET "/companies/$LIVE_COMPANY_ID/live-runs?minCount=0&limit=20" \
      | jq -c '[.[] | {id,status,agentId,issueId,nextAction}]' || true
    bad "engineering process adapter executions start"
  fi
  docker compose exec -T paperclip sh -c "touch '$LIVE_RELEASE'"
  prototype_two="wsroute-proto-alt-$(date +%s)-$$"
  LIVE_PROTO_NAMES="$LIVE_PROTO_NAMES $prototype_two"
  if docker compose exec -T paperclip prototype create "$prototype_two" --idle never >/dev/null; then
    ok "prototype create second test prototype"
  else
    bad "prototype create second test prototype"
    return 1
  fi
  docker compose exec -T paperclip sh -c "rm -f '$LIVE_RELEASE'"
  prototype_two_id="$(live_api GET "/companies/$LIVE_COMPANY_ID/projects" | jq -r --arg n "$prototype_two" '[.[] | select(.name == $n)] | if length == 1 then .[0].id else empty end')"
  prototype_ws="$(live_api GET "/projects/$prototype_id" | jq -r '.primaryWorkspace.id')"
  prototype_two_ws="$(live_api GET "/projects/$prototype_two_id" | jq -r '.primaryWorkspace.id')"
  [ -n "$prototype_two_id" ] && [ -n "$prototype_ws" ] && [ -n "$prototype_two_ws" ] || {
    bad "resolve prototype project and primary workspaces"
    return 1
  }
  LIVE_TEST_PROJECT_IDS="$LIVE_TEST_PROJECT_IDS $prototype_two_id"
  create_process_agent prototype-a "$prototype_id" "$prototype_ws" || { bad "create prototype process agent A"; return 1; }
  test_agent_p1="$LIVE_CREATED_AGENT_ID"
  create_process_agent prototype-b "$prototype_id" "$prototype_ws" || { bad "create prototype process agent B"; return 1; }
  test_agent_p2="$LIVE_CREATED_AGENT_ID"
  create_process_agent prototype-c "$prototype_two_id" "$prototype_two_ws" || { bad "create prototype process agent C"; return 1; }
  test_agent_p3="$LIVE_CREATED_AGENT_ID"
  issue_payload="$(jq -nc --arg p "$prototype_id" --arg w "$prototype_ws" --arg a "$test_agent_p1" --arg marker "$LIVE_MARKER" \
    '{title:"prototype serialization A",description:($marker+" prototype A"),status:"todo",
      projectId:$p,projectWorkspaceId:$w,assigneeAgentId:$a,executionWorkspaceSettings:{mode:"inherit"}}')"
  create_issue "$issue_payload" || { bad "create prototype issue A"; return 1; }
  prototype_issue_a="$LIVE_CREATED_ISSUE_ID"
  issue_payload="$(jq -nc --arg p "$prototype_id" --arg w "$prototype_ws" --arg a "$test_agent_p2" --arg marker "$LIVE_MARKER" \
    '{title:"prototype serialization B",description:($marker+" prototype B"),status:"todo",
      projectId:$p,projectWorkspaceId:$w,assigneeAgentId:$a,executionWorkspaceSettings:{mode:"inherit"}}')"
  create_issue "$issue_payload" || { bad "create prototype issue B"; return 1; }
  prototype_issue_b="$LIVE_CREATED_ISSUE_ID"
  LIVE_PROJECT_ISSUE_IDS="$LIVE_PROJECT_ISSUE_IDS $prototype_issue_a $prototype_issue_b"
  wake_issue "$test_agent_p1" "$prototype_issue_a" || return 1
  for _ in $(seq 1 30); do
    paths="$(docker compose exec -T paperclip sh -c "cat '$LIVE_RECORD' 2>/dev/null || true")"
    printf '%s\n' "$paths" | awk '$1 == "prototype-a" {found=1} END {exit !found}' && break
    sleep 1
  done
  wake_issue "$test_agent_p2" "$prototype_issue_b" || return 1
  queued=0
  for _ in $(seq 1 30); do
    run_json="$(live_api GET "/companies/$LIVE_COMPANY_ID/heartbeat-runs?limit=1000" 2>/dev/null || printf '[]')"
    if printf '%s' "$run_json" | jq -e --arg id "$prototype_issue_b" \
      'any(.[]?; (.issueId == $id or .contextSnapshot.issueId == $id)
        and .status == "scheduled_retry"
        and .scheduledRetryReason == "workspace_busy")' >/dev/null 2>&1; then
      queued=1
      break
    fi
    sleep 1
  done
  if [ "$queued" -eq 1 ]; then
    ok "same-prototype second run is scheduled_retry workspace_busy"
  else
    bad "same-prototype second run is scheduled_retry workspace_busy"
    live_api GET "/companies/$LIVE_COMPANY_ID/heartbeat-runs?limit=1000" \
      | jq -c '[.[] | {id,status,issueId,scheduledRetryReason}]' || true
    return 1
  fi
  issue_payload="$(jq -nc --arg p "$prototype_two_id" --arg w "$prototype_two_ws" --arg a "$test_agent_p3" --arg marker "$LIVE_MARKER" \
    '{title:"prototype concurrency C",description:($marker+" prototype C"),status:"todo",
      projectId:$p,projectWorkspaceId:$w,assigneeAgentId:$a,executionWorkspaceSettings:{mode:"inherit"}}')"
  create_issue "$issue_payload" || { bad "create prototype issue C"; return 1; }
  prototype_issue_c="$LIVE_CREATED_ISSUE_ID"
  LIVE_PROJECT_ISSUE_IDS="$LIVE_PROJECT_ISSUE_IDS $prototype_issue_c"
  wake_issue "$test_agent_p3" "$prototype_issue_c" || return 1
  concurrent=0
  for _ in $(seq 1 30); do
    paths="$(docker compose exec -T paperclip sh -c "cat '$LIVE_RECORD' 2>/dev/null || true")"
    printf '%s\n' "$paths" | awk '$1 == "prototype-c" {found=1} END {exit !found}' && { concurrent=1; break; }
    sleep 1
  done
  [ "$concurrent" -eq 1 ] && ok "different-prototype run executes while first is held" \
    || { bad "different-prototype run executes while first is held"; live_api GET "/companies/$LIVE_COMPANY_ID/live-runs?minCount=0&limit=20" | jq -c '[.[] | {id,status,issueId,nextAction}]' || true; }
  docker compose exec -T paperclip sh -c "touch '$LIVE_RELEASE'"
  docker compose exec -T paperclip rm -f "$adapter_script" "$LIVE_RECORD" "$LIVE_RELEASE"
  echo "INFO  process-adapter routing evidence collected; failures above are blockers, not passes"
  if printf '%s' "$project_json" | jq -e --arg ws "$(printf '%s' "$project_json" | jq -r '.primaryWorkspace.id')" '
    .executionWorkspacePolicy.defaultMode == "shared_workspace"
    and .executionWorkspacePolicy.sharedWorkspaceConcurrency == "serialize"
    and .executionWorkspacePolicy.workspaceStrategy.type == "project_primary"
    and .executionWorkspacePolicy.defaultProjectWorkspaceId == $ws' >/dev/null 2>&1; then
    ok "prototype policy identity and persistence verified"
  else
    bad "prototype policy identity and persistence verified"
  fi
  if [ "$FAIL" -eq "$fail_before" ]; then
    return 0
  fi
  return 1
}

PASS=0 FAIL=0
if [ "$MODE" = live ]; then
  live_gate
  live_status=$?
  live_cleanup
  cleanup_status=$?
  trap - EXIT INT TERM
  [ "$live_status" -eq 0 ] && [ "$cleanup_status" -eq 0 ] || exit 1
  exit 0
fi
assert_contains() { local label="$1" needle="$2" haystack="$3"; [[ "$haystack" == *"$needle"* ]] && ok "$label" || { bad "$label (missing=$needle)"; return 1; }; }
assert_not_contains() { local label="$1" needle="$2" haystack="$3"; [[ "$haystack" != *"$needle"* ]] && ok "$label" || { bad "$label (found=$needle)"; return 1; }; }
CLI=patches/hermes/opc-paperclip

assert_eq "https repo identity" "github.com/owner/repo" \
  "$($CLI repo normalize https://github.com/Owner/Repo.git | jq -r .identity)"
assert_eq "scp repo identity" "github.com/owner/repo" \
  "$($CLI repo normalize git@github.com:Owner/Repo.git | jq -r .identity)"
assert_eq "short repo URL" "https://github.com/owner/repo" \
  "$($CLI repo normalize Owner/Repo | jq -r .repoUrl)"
assert_eq "trailing URL slash is normalized" "https://github.com/owner/repo" \
  "$($CLI repo normalize https://github.com/Owner/Repo/ | jq -r .repoUrl)"
for invalid_repo in 'https://gitlab.com/owner/repo' 'http://github.com/owner/repo' 'git@evil:owner/repo' '/tmp/repo' 'Owner/' 'Owner/Repo/'; do
  if $CLI repo normalize "$invalid_repo" >/dev/null 2>&1; then
    bad "invalid repository identity is rejected: $invalid_repo"
  else
    ok "invalid repository identity is rejected: $invalid_repo"
  fi
done
cmp -s patches/buzz/opc-paperclip patches/hermes/opc-paperclip \
  && ok "CLI copies are identical" || bad "CLI copies are identical"

for decision_case in "20||4|apply" "6||4|preserve" "4|4|4|keep" "4|4|5|apply" "6|4|4|preserve" "4|3|4|preserve"; do
  IFS='|' read -r current marker default expected <<<"$decision_case"
  actual="$(
    OPC_PAPERCLIP_BOOTSTRAP_LIB_ONLY=1 sh -c \
      '. patches/paperclip/opc-paperclip-bootstrap.sh
       opc_managed_concurrency_action "$1" "$2" "$3"' \
      sh "$current" "$marker" "$default"
  )"
  assert_eq "managed concurrency decision $current/$marker/$default" "$expected" "$actual"
done

TMPDIR="$(mktemp -d)"
STATE="$TMPDIR/state.json"
LOG="$TMPDIR/fixture.log"
TOKEN=fixture-key
# Pick a port nothing is already listening on.
#
# This used to be `39000 + ($$ % 1000)` with no check, and a collision did not
# fail cleanly: the fixture never came up, every later assertion talked to
# WHATEVER owned the port, and the run produced 88 cascading "want=X got="
# failures pointing at a stranger's 404s. Observed with a foreign listener on
# 127.0.0.1:39249. Probe first, and let PAPERCLIP_FIXTURE_PORT force a specific
# port when a caller needs one.
port_is_free() {
  ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}
pick_free_port() {
  local base="$((39000 + ($$ % 1000)))" candidate i
  for i in $(seq 0 199); do
    candidate="$(( 39000 + ((base - 39000 + i) % 1000) ))"
    if port_is_free "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}
if [ -n "${PAPERCLIP_FIXTURE_PORT:-}" ]; then
  PORT="$PAPERCLIP_FIXTURE_PORT"
else
  PORT="$(pick_free_port)" || {
    echo "FAIL  no free loopback port in 39000-39999 for the fixture" >&2
    exit 1
  }
fi
FIXTURE_PID=""
stop_fixture() {
  if [ -n "$FIXTURE_PID" ]; then
    kill "$FIXTURE_PID" 2>/dev/null || true
    wait "$FIXTURE_PID" 2>/dev/null || true
    FIXTURE_PID=""
  fi
}
cleanup() { stop_fixture; rm -rf "$TMPDIR"; }
trap cleanup EXIT INT TERM
start_fixture() {
  : >"$LOG"
  PAPERCLIP_FIXTURE_STATE="$STATE" python3 tests/fixtures/paperclip-workspace-api.py "$PORT" >"$LOG" 2>&1 &
  FIXTURE_PID=$!
  for _try in $(seq 1 100); do
    if curl -fsS -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
done
  # Fatal, not a recorded failure. Callers invoke start_fixture bare and ignore
  # its return, so continuing means running the whole offline suite against
  # something that is not the fixture — which is how one port collision turned
  # into 88 meaningless failures. If the local stub will not start, the
  # environment is broken and there is nothing to salvage by carrying on.
  bad "fixture starts on loopback port $PORT"
  echo "── fixture log ──" >&2
  sed 's/^/    /' "$LOG" >&2
  if ! port_is_free "$PORT"; then
    echo "    (port $PORT is held by another process — the fixture never bound it)" >&2
  fi
  exit 1
}
cat >"$STATE" <<'JSON'
{
  "experimental": {"enableIsolatedWorkspaces": false},
  "company": {"id": "00000000-0000-4000-8000-000000000001", "name": "Fixture"},
  "agents": [{
    "id": "00000000-0000-4000-8000-000000000010",
    "name": "Fullstack Engineer",
    "role": "engineer",
    "status": "idle",
    "runtimeConfig": {"heartbeat": {"maxConcurrentRuns": 4, "fixtureKeep": true}, "modelProfiles": {"cheap": {"enabled": false, "label": "fixture"}}},
    "metadata": {"opcManagedDefaults": {"fullstackMaxConcurrentRuns": 4}, "fixtureKeep": "yes"}
  }],
  "projects": [{
    "id": "00000000-0000-4000-8000-000000000101",
    "name": "Display Name Is Not Identity",
    "executionWorkspacePolicy": {"defaultMode": "isolated_workspace", "workspaceStrategy": {"type": "git_worktree"}},
    "primaryWorkspace": {
      "id": "00000000-0000-4000-8000-000000000201",
      "repoUrl": "ssh://git@github.com/Owner/Repo.git",
      "isPrimary": true,
      "metadata": {"fixture": "kept"}
    },
    "workspaces": [{
      "id": "00000000-0000-4000-8000-000000000201",
      "repoUrl": "ssh://git@github.com/Owner/Repo.git",
      "isPrimary": true
    }]
  }],
  "issues": []
}
JSON
start_fixture
export PAPERCLIP_API_URL="http://127.0.0.1:$PORT"
export PAPERCLIP_API_KEY="$TOKEN"
assert_eq "experimental GET starts disabled" "false" \
  "$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    "$PAPERCLIP_API_URL/api/instance/settings/experimental" | jq -r .enableIsolatedWorkspaces)"
EXPERIMENTAL_PATCH="$(curl -fsS -X PATCH -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  "$PAPERCLIP_API_URL/api/instance/settings/experimental" \
  -d '{"enableIsolatedWorkspaces":true,"fixtureKeep":"yes"}')"
assert_eq "experimental PATCH enables workspaces" "true" \
  "$(printf '%s' "$EXPERIMENTAL_PATCH" | jq -r .enableIsolatedWorkspaces)"
assert_eq "experimental PATCH preserves unrelated key" "yes" \
  "$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    "$PAPERCLIP_API_URL/api/instance/settings/experimental" | jq -r .fixtureKeep)"
SHOW_ERR="$TMPDIR/show.err"
if SHOW="$($CLI project workspace show --repo https://github.com/owner/repo/ 2>"$SHOW_ERR")"; then

  ok "project workspace show succeeds for canonical-equivalent SSH URL"
  assert_eq "show project id" "00000000-0000-4000-8000-000000000101" "$(printf '%s' "$SHOW" | jq -r .project.id)"
  assert_eq "show project display name" "Display Name Is Not Identity" "$(printf '%s' "$SHOW" | jq -r .project.name)"
  assert_eq "show workspace id" "00000000-0000-4000-8000-000000000201" "$(printf '%s' "$SHOW" | jq -r .workspace.id)"
  assert_eq "show workspace URL" "ssh://git@github.com/Owner/Repo.git" "$(printf '%s' "$SHOW" | jq -r .workspace.repoUrl)"
  assert_eq "show primary marker" "true" "$(printf '%s' "$SHOW" | jq -r .workspace.isPrimary)"

  assert_eq "show policy mode" "isolated_workspace" "$(printf '%s' "$SHOW" | jq -r .policy.defaultMode)"
  assert_eq "show policy strategy" "git_worktree" "$(printf '%s' "$SHOW" | jq -r .policy.workspaceStrategy.type)"
  assert_eq "show reports unmanaged source" "unmanaged" "$(printf '%s' "$SHOW" | jq -r .source)"
  assert_eq "show omits arbitrary workspace metadata" "false" "$(printf '%s' "$SHOW" | jq 'has("env") or has("runtime") or (.workspace | has("metadata"))')"
else
  bad "project workspace show succeeds for canonical-equivalent SSH URL"
fi
assert_not_contains "fixture log omits bearer token" "$TOKEN" "$(cat "$LOG")"
assert_eq "engineer concurrency show" "4" \
  "$($CLI agent concurrency show --role engineer | jq -r .maxConcurrentRuns)"
$CLI agent concurrency set --role engineer --max 6 >/dev/null
assert_eq "operator concurrency set" "6" \
  "$($CLI agent concurrency show --role engineer | jq -r .maxConcurrentRuns)"
assert_eq "set is marked override" "operator_override" \
  "$($CLI agent concurrency show --role engineer | jq -r .source)"
assert_eq "agent PATCH repairs cheap profile schema" "object" \
  "$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    "$PAPERCLIP_API_URL/api/companies/00000000-0000-4000-8000-000000000001/agents" \
    | jq -r '.[0].runtimeConfig.modelProfiles.cheap.adapterConfig | type')"
assert_eq "agent PATCH preserves cheap profile enabled" "false" \
  "$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    "$PAPERCLIP_API_URL/api/companies/00000000-0000-4000-8000-000000000001/agents" \
    | jq -r '.[0].runtimeConfig.modelProfiles.cheap.enabled')"
assert_eq "agent PATCH preserves cheap profile label" "fixture" \
  "$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    "$PAPERCLIP_API_URL/api/companies/00000000-0000-4000-8000-000000000001/agents" \
    | jq -r '.[0].runtimeConfig.modelProfiles.cheap.label')"
assert_eq "agent PATCH preserves runtime sibling" "true" \
  "$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    "$PAPERCLIP_API_URL/api/companies/00000000-0000-4000-8000-000000000001/agents" \
    | jq -r '.[0].runtimeConfig.heartbeat.fixtureKeep')"
assert_eq "agent PATCH preserves metadata sibling" "yes" \
  "$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    "$PAPERCLIP_API_URL/api/companies/00000000-0000-4000-8000-000000000001/agents" \
    | jq -r '.[0].metadata.fixtureKeep')"

$CLI agent concurrency set --role engineer --max 6 >/dev/null
curl -fsS -X PATCH -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  "$PAPERCLIP_API_URL/api/agents/00000000-0000-4000-8000-000000000010" \
  -d '{"metadata":{"opcManagedDefaults":{"fullstackMaxConcurrentRuns":3},"fixtureKeep":"yes"}}' >/dev/null
$CLI agent concurrency reset --role engineer >/dev/null
assert_eq "concurrency reset" "4" \
  "$($CLI agent concurrency show --role engineer | jq -r .maxConcurrentRuns)"
assert_eq "reset is marked managed_default" "managed_default" \
  "$($CLI agent concurrency show --role engineer | jq -r .source)"
assert_eq "reset updates managed marker" "4" \
  "$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    "$PAPERCLIP_API_URL/api/companies/00000000-0000-4000-8000-000000000001/agents" \
    | jq -r '.[0].metadata.opcManagedDefaults.fullstackMaxConcurrentRuns')"
assert_eq "reset preserves cheap profile schema" "object" \
  "$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    "$PAPERCLIP_API_URL/api/companies/00000000-0000-4000-8000-000000000001/agents" \
    | jq -r '.[0].runtimeConfig.modelProfiles.cheap.adapterConfig | type')"
curl -fsS -X PATCH -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  "$PAPERCLIP_API_URL/api/agents/00000000-0000-4000-8000-000000000010" \
  -d '{"runtimeConfig":{"heartbeat":{"maxConcurrentRuns":4},"modelProfiles":{}}}' >/dev/null
$CLI agent concurrency set --role engineer --max 6 >/dev/null
assert_eq "set leaves absent cheap profile absent" "null" \
  "$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    "$PAPERCLIP_API_URL/api/companies/00000000-0000-4000-8000-000000000001/agents" \
    | jq -r '.[0].runtimeConfig.modelProfiles.cheap // null')"
curl -fsS -X PATCH -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  "$PAPERCLIP_API_URL/api/agents/00000000-0000-4000-8000-000000000010" \
  -d '{"runtimeConfig":{"heartbeat":{"maxConcurrentRuns":4},"modelProfiles":{"cheap":null}}}' >/dev/null
$CLI agent concurrency reset --role engineer >/dev/null
assert_eq "reset leaves null cheap profile null" "null" \
  "$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    "$PAPERCLIP_API_URL/api/companies/00000000-0000-4000-8000-000000000001/agents" \
    | jq -r '.[0].runtimeConfig.modelProfiles.cheap // null')"

for invalid_max in 0 51; do
  before="$(cat "$STATE")"
  if $CLI agent concurrency set --role engineer --max "$invalid_max" >/dev/null 2>&1; then
    bad "concurrency rejects max $invalid_max"
  else
    ok "concurrency rejects max $invalid_max"
  fi
  assert_eq "invalid max $invalid_max does not PATCH" "$before" "$(cat "$STATE")"
done

before_policy_failure_issues="$(jq '.issues | length' "$STATE")"
stop_fixture
python3 - "$STATE" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    state = json.load(stream)
state["faults"] = {"omitProjectPolicyFields": ["defaultMode"]}
with open(path, "w", encoding="utf-8") as stream:
    json.dump(state, stream)
    stream.write("\n")
PY
start_fixture
POLICY_VERIFY_ERR="$TMPDIR/policy-verify.err"
if printf x | "$CLI" engineering-ticket create --repo Owner/VerifyFail \
  --title policy-verification-failure >/dev/null 2>"$POLICY_VERIFY_ERR"; then
  bad "engineering adoption fails closed when policy response omits mode"
else
  ok "engineering adoption fails closed when policy response omits mode"
fi
assert_contains "policy verification error is actionable" "policy was not verified" "$(cat "$POLICY_VERIFY_ERR")"
assert_eq "policy verification failure creates no issue" "$before_policy_failure_issues" "$(jq '.issues | length' "$STATE")"
assert_eq "policy verification failure leaves no marker" "null" \
  "$(jq -r '[.projects[] | select(.primaryWorkspace.repoUrl == "https://github.com/owner/verifyfail")][0].primaryWorkspace.metadata.opcWorkspaceDefaults // null' "$STATE")"
stop_fixture
python3 - "$STATE" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    state = json.load(stream)
state.pop("faults", None)
with open(path, "w", encoding="utf-8") as stream:
    json.dump(state, stream)
    stream.write("\n")
PY
stop_fixture
cat >"$STATE" <<'JSON'
{
  "experimental": {"enableIsolatedWorkspaces": false},
  "company": {"id": "00000000-0000-4000-8000-000000000001", "name": "Fixture"},
  "agents": [{
    "id": "00000000-0000-4000-8000-000000000011",
    "name": "Engineer One",
    "role": "engineer",
    "status": "idle"
  }],
  "projects": [],
  "issues": []
}
JSON
start_fixture
export PAPERCLIP_API_URL="http://127.0.0.1:$PORT"
export PAPERCLIP_API_KEY="$TOKEN"
printf '%s' 'Acceptance: tests pass' | \
  "$CLI" engineering-ticket create \
    --repo git@github.com:Owner/Repo.git --title 'Fix race' --priority high \
    >"$TMPDIR/result.json"
assert_eq "engineering project auto-created once" "1" \
  "$(jq '[.projects[] | select(.primaryWorkspace.repoUrl == "https://github.com/owner/repo")] | length' "$STATE")"
assert_eq "engineering project default mode" "isolated_workspace" \
  "$(jq -r '.projects[0].executionWorkspacePolicy.defaultMode' "$STATE")"
assert_eq "engineering strategy" "git_worktree" \
  "$(jq -r '.projects[0].executionWorkspacePolicy.workspaceStrategy.type' "$STATE")"
assert_eq "ticket inherits project policy" "inherit" \
  "$(jq -r '.issues[0].executionWorkspaceSettings.mode' "$STATE")"
assert_eq "ticket binds primary workspace" \
  "$(jq -r '.projects[0].primaryWorkspace.id' "$STATE")" \
  "$(jq -r '.issues[0].projectWorkspaceId' "$STATE")"
printf x | "$CLI" engineering-ticket create \
  --repo https://github.com/OWNER/REPO --title 'Second form' >/dev/null
assert_eq "canonical-equivalent ticket reuses project" "1" \
  "$(jq '[.projects[] | select(.primaryWorkspace.repoUrl == "https://github.com/owner/repo")] | length' "$STATE")"
assert_eq "two tickets persisted" "2" "$(jq '.issues | length' "$STATE")"
stop_fixture
python3 - "$STATE" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    state = json.load(stream)
state["projects"].append({
    "id": "00000000-0000-4000-8000-000000000151",
    "name": "Unrelated Project",
    "primaryWorkspace": {
        "id": "00000000-0000-4000-8000-000000000251",
        "repoUrl": "https://github.com/other/unrelated",
        "isPrimary": True,
    },
    "workspaces": [{
        "id": "00000000-0000-4000-8000-000000000251",
        "repoUrl": "https://github.com/other/unrelated",
        "isPrimary": True,
    }],
})
with open(path, "w", encoding="utf-8") as stream:
    json.dump(state, stream)
    stream.write("\n")
PY
start_fixture
export PAPERCLIP_API_URL="http://127.0.0.1:$PORT"
export PAPERCLIP_API_KEY="$TOKEN"
printf x | "$CLI" engineering-ticket create --repo Owner/NewRepo --title unrelated-project-regression >/dev/null
assert_eq "unrelated project does not block registration" "1" \
  "$(jq '[.projects[] | select(.primaryWorkspace.repoUrl == "https://github.com/owner/newrepo")] | length' "$STATE")"
assert_eq "unrelated-project ticket persisted" "3" "$(jq '.issues | length' "$STATE")"
NO_MATCH_ERR="$TMPDIR/no-match.err"
if "$CLI" project workspace show --repo Owner/Missing >/dev/null 2>"$NO_MATCH_ERR"; then
  bad "no-match project lookup fails closed"
else
  ok "no-match project lookup fails closed"
fi
assert_contains "no-match project error is actionable" "no Paperclip project matches" "$(cat "$NO_MATCH_ERR")"
before_ambiguous_issues="$(jq '.issues | length' "$STATE")"
python3 - "$STATE" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    state = json.load(stream)
state["projects"].append({
    "id": "00000000-0000-4000-8000-000000000111",
    "name": "Ambiguous Engineering",
    "primaryWorkspace": {
        "id": "00000000-0000-4000-8000-000000000211",
        "repoUrl": "https://github.com/owner/repo",
        "isPrimary": True,
    },
    "workspaces": [{
        "id": "00000000-0000-4000-8000-000000000211",
        "repoUrl": "https://github.com/owner/repo",
        "isPrimary": True,
    }],
})
with open(path, "w", encoding="utf-8") as stream:
    json.dump(state, stream)
    stream.write("\n")
PY
stop_fixture
start_fixture
export PAPERCLIP_API_URL="http://127.0.0.1:$PORT"
export PAPERCLIP_API_KEY="$TOKEN"
AMBIGUOUS_TICKET_ERR="$TMPDIR/engineering-ambiguous.err"
if printf x | "$CLI" engineering-ticket create --repo Owner/Repo --title ambiguous \
  >/dev/null 2>"$AMBIGUOUS_TICKET_ERR"; then
  bad "ambiguous engineering projects fail closed"
else
  ok "ambiguous engineering projects fail closed"
fi
assert_contains "engineering ambiguity lists first project" "00000000-0000-4000-8000-000000000102" "$(cat "$AMBIGUOUS_TICKET_ERR")"
assert_contains "engineering ambiguity lists second project" "00000000-0000-4000-8000-000000000111" "$(cat "$AMBIGUOUS_TICKET_ERR")"
assert_eq "ambiguous engineering creates no issue" "$before_ambiguous_issues" "$(jq '.issues | length' "$STATE")"
python3 - "$STATE" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    state = json.load(stream)
state["projects"] = [state["projects"][0]]
with open(path, "w", encoding="utf-8") as stream:
    json.dump(state, stream)
    stream.write("\n")
PY
stop_fixture
python3 - "$STATE" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    state = json.load(stream)
workspace = state["projects"][0]["primaryWorkspace"]
workspace.setdefault("metadata", {}).pop("opcWorkspaceDefaults", None)
with open(path, "w", encoding="utf-8") as stream:
    json.dump(state, stream)
    stream.write("\n")
PY
start_fixture
export PAPERCLIP_API_URL="http://127.0.0.1:$PORT"
export PAPERCLIP_API_KEY="$TOKEN"
SET_OUTPUT="$("$CLI" project workspace set --repo Owner/Repo --mode shared_workspace \
  --shared-concurrency serialize --strategy project_primary)"
assert_eq "workspace set marks operator override" "operatorOverride" \
  "$(jq -r '.projects[0].primaryWorkspace.metadata.opcWorkspaceDefaults.source' "$STATE")"
assert_eq "workspace set output reports override" "operator_override" \
  "$(printf '%s' "$SET_OUTPUT" | jq -r .source)"
assert_eq "workspace set verifies enabled policy" "true" \
  "$(printf '%s' "$SET_OUTPUT" | jq -r '.policy.enabled')"
assert_eq "workspace set verifies shared concurrency" "serialize" \
  "$(printf '%s' "$SET_OUTPUT" | jq -r '.policy.sharedConcurrency')"
printf x | "$CLI" engineering-ticket create --repo Owner/Repo --title override-preserved >/dev/null
assert_eq "operator project override survives routing" "shared_workspace" \
  "$(jq -r '.projects[0].executionWorkspacePolicy.defaultMode' "$STATE")"
assert_eq "routed override ticket still inherits" "inherit" \
  "$(jq -r '.issues[-1].executionWorkspaceSettings.mode' "$STATE")"
"$CLI" project workspace reset --repo Owner/Repo --lane engineering >/dev/null
assert_eq "engineering reset mode" "isolated_workspace" \
  "$(jq -r '.projects[0].executionWorkspacePolicy.defaultMode' "$STATE")"
assert_eq "engineering reset strategy" "git_worktree" \
  "$(jq -r '.projects[0].executionWorkspacePolicy.workspaceStrategy.type' "$STATE")"
policy_before_ticket_override="$(jq -c '.projects[0].executionWorkspacePolicy' "$STATE")"
printf x | "$CLI" engineering-ticket create --repo Owner/Repo --title one-ticket \
  --mode shared_workspace >/dev/null
assert_eq "one-ticket override mode" "shared_workspace" \
  "$(jq -r '.issues[-1].executionWorkspaceSettings.mode' "$STATE")"
assert_eq "one-ticket override does not mutate policy" "$policy_before_ticket_override" \
  "$(jq -c '.projects[0].executionWorkspacePolicy' "$STATE")"
before_reuse_issues="$(jq '.issues | length' "$STATE")"
REUSE_ERR="$TMPDIR/reuse-existing.err"
if printf x | "$CLI" engineering-ticket create --repo Owner/Repo --title reuse \
  --mode reuse_existing >/dev/null 2>"$REUSE_ERR"; then
  bad "reuse_existing requires explicit execution workspace"
else
  ok "reuse_existing requires explicit execution workspace"
fi
assert_contains "reuse_existing error names required option" "--execution-workspace-id" "$(cat "$REUSE_ERR")"
assert_eq "reuse_existing validation creates no issue" "$before_reuse_issues" "$(jq '.issues | length' "$STATE")"
ADAPTER_OVERRIDE_ERR="$TMPDIR/adapter-override.err"
if printf x | "$CLI" engineering-ticket create --repo Owner/Repo --title adapter \
  --mode adapter_default --execution-workspace-id ignored >/dev/null 2>"$ADAPTER_OVERRIDE_ERR"; then
  bad "adapter_default rejects execution workspace override"
else
  ok "adapter_default rejects execution workspace override"
fi
assert_contains "adapter_default error names incompatible option" "--execution-workspace-id" "$(cat "$ADAPTER_OVERRIDE_ERR")"

printf 'line one\nline two\n' | "$CLI" engineering-ticket create --repo Owner/Repo \
  --title newline-description --mode reuse_existing \
  --execution-workspace-id "$(jq -r '.projects[0].primaryWorkspace.id' "$STATE")" >/dev/null
python3 - "$STATE" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    state = json.load(stream)
assert state["issues"][-1]["description"] == "line one\nline two\n"
assert state["issues"][-1]["executionWorkspacePreference"] == "reuse_existing"
assert state["issues"][-1]["executionWorkspaceId"] == state["issues"][-1]["projectWorkspaceId"]
assert "executionWorkspaceId" not in state["issues"][-1]["executionWorkspaceSettings"]
PY
ok "reuse_existing stores top-level execution workspace fields"
ok "description preserves trailing newline"
before_ineligible_issues="$(jq '.issues | length' "$STATE")"
stop_fixture
python3 - "$STATE" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    state = json.load(stream)
state["agents"][0]["status"] = "paused"
with open(path, "w", encoding="utf-8") as stream:
    json.dump(state, stream)
    stream.write("\n")
PY
start_fixture
PAUSED_ERR="$TMPDIR/paused-engineer.err"
if printf x | "$CLI" engineering-ticket create --repo Owner/Repo --title paused \
  >/dev/null 2>"$PAUSED_ERR"; then
  bad "paused engineer fails closed"
else
  ok "paused engineer fails closed"
fi
assert_contains "paused engineer error is actionable" "no active Paperclip agent" "$(cat "$PAUSED_ERR")"
assert_eq "paused engineer creates no issue" "$before_ineligible_issues" "$(jq '.issues | length' "$STATE")"
stop_fixture
python3 - "$STATE" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    state = json.load(stream)
state["agents"][0]["status"] = "pending_approval"
with open(path, "w", encoding="utf-8") as stream:
    json.dump(state, stream)
    stream.write("\n")
PY
start_fixture
PENDING_ERR="$TMPDIR/pending-engineer.err"
if printf x | "$CLI" engineering-ticket create --repo Owner/Repo --title pending \
  >/dev/null 2>"$PENDING_ERR"; then
  bad "pending-approval engineer fails closed"
else
  ok "pending-approval engineer fails closed"
fi
assert_contains "pending engineer error is actionable" "no active Paperclip agent" "$(cat "$PENDING_ERR")"
assert_eq "pending engineer creates no issue" "$before_ineligible_issues" "$(jq '.issues | length' "$STATE")"
stop_fixture
python3 - "$STATE" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    state = json.load(stream)
state["agents"][0]["status"] = "idle"
with open(path, "w", encoding="utf-8") as stream:
    json.dump(state, stream)
    stream.write("\n")
PY
start_fixture
export PAPERCLIP_API_URL="http://127.0.0.1:$PORT"
export PAPERCLIP_API_KEY="$TOKEN"

stop_fixture
cat >"$STATE" <<'JSON'
{
  "experimental": {"enableIsolatedWorkspaces": false},
  "company": {"id": "00000000-0000-4000-8000-000000000001", "name": "Fixture"},
  "agents": [],
  "projects": [{
    "id": "00000000-0000-4000-8000-000000000111",
    "name": "Ambiguous",
    "workspaces": [
      {"id": "00000000-0000-4000-8000-000000000211", "repoUrl": "https://github.com/owner/repo", "isPrimary": true},
      {"id": "00000000-0000-4000-8000-000000000212", "repoUrl": "https://github.com/owner/repo/", "isPrimary": true}
    ]
  }],
  "issues": []
}
JSON
start_fixture
MULTI_ERR="$TMPDIR/multiple.err"
if $CLI project workspace show --repo Owner/Repo >/dev/null 2>"$MULTI_ERR"; then
  bad "multiple primary workspaces fail closed"
else
  ok "multiple primary workspaces fail closed"
fi
assert_contains "multiple-primary error is actionable" "multiple primary workspaces" "$(cat "$MULTI_ERR")"
assert_not_contains "multiple-primary stderr omits bearer token" "$TOKEN" "$(cat "$MULTI_ERR")"
assert_not_contains "multiple-primary fixture log omits bearer token" "$TOKEN" "$(cat "$LOG")"

stop_fixture
cat >"$STATE" <<'JSON'
{
  "experimental": {"enableIsolatedWorkspaces": false},
  "company": {"id": "00000000-0000-4000-8000-000000000001", "name": "Fixture"},
  "agents": [],
  "projects": [
    {
      "id": "00000000-0000-4000-8000-000000000121",

      "name": "Alpha",
      "workspaces": [
        {"id": "00000000-0000-4000-8000-000000000221", "repoUrl": "https://github.com/owner/repo", "isPrimary": true}
      ]
    },
    {
      "id": "00000000-0000-4000-8000-000000000122",
      "name": "Beta",
      "workspaces": [
        {"id": "00000000-0000-4000-8000-000000000222", "repoUrl": "ssh://git@github.com/owner/repo.git", "isPrimary": true}
      ]
    }
  ],
  "issues": []
}
JSON
start_fixture
DUPLICATE_ERR="$TMPDIR/duplicate.err"
if $CLI project workspace show --repo Owner/Repo >/dev/null 2>"$DUPLICATE_ERR"; then
  bad "duplicate matching projects fail closed"
else
  ok "duplicate matching projects fail closed"
fi
assert_contains "duplicate error includes first project ID/name" "00000000-0000-4000-8000-000000000121 Alpha" "$(cat "$DUPLICATE_ERR")"
assert_contains "duplicate error includes second project ID/name" "00000000-0000-4000-8000-000000000122 Beta" "$(cat "$DUPLICATE_ERR")"
assert_not_contains "duplicate stderr omits bearer token" "$TOKEN" "$(cat "$DUPLICATE_ERR")"
assert_not_contains "duplicate fixture log omits bearer token" "$TOKEN" "$(cat "$LOG")"
stop_fixture
cat >"$STATE" <<'JSON'
{
  "experimental": {"enableIsolatedWorkspaces": false},
  "company": {"id": "00000000-0000-4000-8000-000000000001", "name": "Fixture"},
  "agents": [
    {"id": "00000000-0000-4000-8000-000000000031", "name": "Engineer A", "role": "engineer"},
    {"id": "00000000-0000-4000-8000-000000000032", "name": "Engineer B", "role": "engineer"}
  ],
  "projects": [],
  "issues": []
}
JSON
start_fixture
AGENT_AMBIGUOUS_ERR="$TMPDIR/agent-ambiguous.err"
if $CLI agent concurrency show --role engineer >/dev/null 2>"$AGENT_AMBIGUOUS_ERR"; then
  bad "multiple engineer agents fail closed"
else
  ok "multiple engineer agents fail closed"
fi
assert_contains "multiple-engineer error is actionable" "multiple Paperclip agents match role engineer" "$(cat "$AGENT_AMBIGUOUS_ERR")"
assert_not_contains "multiple-engineer stderr omits bearer token" "$TOKEN" "$(cat "$AGENT_AMBIGUOUS_ERR")"

stop_fixture
cat >"$STATE" <<'JSON'
{
  "experimental": {"enableIsolatedWorkspaces": false},
  "company": {"id": "00000000-0000-4000-8000-000000000001", "name": "Fixture"},
  "agents": [{
    "id": "00000000-0000-4000-8000-000000000010",
    "name": "Prototyper",
    "role": "prototyper",
    "status": "idle"
  }],
  "projects": [],
  "issues": []
}
JSON
start_fixture
export PAPERCLIP_API_URL="http://127.0.0.1:$PORT"
export PAPERCLIP_API_KEY="$TOKEN"
printf 'Prototype: recipe-bot\nLane: prototype\nAcceptance: preview URL is posted\n' |
  "$CLI" prototype-ticket create --name recipe-bot --title 'Recipe preview' >"$TMPDIR/prototype-first.json"
assert_eq "prototype first ticket has no project" "null" \
  "$(jq -r '.projectId // null' "$TMPDIR/prototype-first.json")"
first_prototype_id="$(jq -r '.id' "$TMPDIR/prototype-first.json")"
printf 'Prototype: recipe-bot\nLane: prototype\nAcceptance: preview URL is posted\n' |
  "$CLI" prototype-ticket create --name recipe-bot --title 'Duplicate' >"$TMPDIR/prototype-duplicate.json"
assert_eq "prototype duplicate returns first issue" "$first_prototype_id" \
  "$(jq -r '.id' "$TMPDIR/prototype-duplicate.json")"
assert_eq "prototype duplicate does not create issue" "1" "$(jq '.issues | length' "$STATE")"
python3 - "$STATE" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    state = json.load(stream)
state["projects"].append({
    "id": "00000000-0000-4000-8000-000000000121",
    "name": "recipe-bot",
    "primaryWorkspace": {
        "id": "00000000-0000-4000-8000-000000000221",
        "cwd": "/prototypes/recipe-bot",
        "isPrimary": True
    },
    "workspaces": [{
        "id": "00000000-0000-4000-8000-000000000221",
        "cwd": "/prototypes/recipe-bot",
        "isPrimary": True
    }]
})
state["projects"].append({
    "id": "00000000-0000-4000-8000-000000000122",
    "name": "recipe-bot-2",
    "primaryWorkspace": {
        "id": "00000000-0000-4000-8000-000000000222",
        "cwd": "/prototypes/recipe-bot-2",
        "isPrimary": True
    },
    "workspaces": [{
        "id": "00000000-0000-4000-8000-000000000222",
        "cwd": "/prototypes/recipe-bot-2",
        "isPrimary": True
    }]
})
with open(path, "w", encoding="utf-8") as stream:
    json.dump(state, stream)
    stream.write("\n")
PY
stop_fixture
start_fixture
export PAPERCLIP_API_URL="http://127.0.0.1:$PORT"
export PAPERCLIP_API_KEY="$TOKEN"
printf 'Prototype: recipe-bot\nLane: prototype\nAcceptance: preview URL is posted\n' |
  "$CLI" prototype-ticket create --name recipe-bot --title 'Recipe continuation' >"$TMPDIR/prototype-continuation.json"
assert_eq "prototype continuation binds exact project" \
  "00000000-0000-4000-8000-000000000121" \
  "$(jq -r '.projectId' "$TMPDIR/prototype-continuation.json")"
assert_eq "prototype continuation binds primary workspace" \
  "00000000-0000-4000-8000-000000000221" \
  "$(jq -r '.projectWorkspaceId' "$TMPDIR/prototype-continuation.json")"
before_project_bound_same_title="$(jq '.issues | length' "$STATE")"
printf 'Prototype: recipe-bot\nLane: prototype\nAcceptance: preview URL is posted\n' |
  "$CLI" prototype-ticket create --name recipe-bot --title 'Recipe continuation' >"$TMPDIR/prototype-same-title.json"
assert_eq "project-bound same-title prototype ticket is created" "$((before_project_bound_same_title + 1))" \
  "$(jq '.issues | length' "$STATE")"
assert_eq "project-bound same-title ticket allows duplicate" "true" \
  "$(jq -r '.issues[-1].allowDuplicate' "$STATE")"
assert_eq "project-bound same-title ticket stays bound" \
  "00000000-0000-4000-8000-000000000121" \
  "$(jq -r '.projectId' "$TMPDIR/prototype-same-title.json")"
assert_eq "prototype near-miss does not match" "null" \
  "$(printf 'Prototype: fresh-bot\nLane: prototype\n' | "$CLI" prototype-ticket create --name fresh-bot --title 'Fresh' | jq -r '.projectId // null')"
python3 - "$STATE" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    state = json.load(stream)
for ordinal in (123, 124):
    state["projects"].append({
        "id": f"00000000-0000-4000-8000-000000000{ordinal}",
        "name": "ambiguous-bot",
        "primaryWorkspace": {
            "id": f"00000000-0000-4000-8000-000000000{ordinal + 100}",
            "cwd": "/prototypes/ambiguous-bot",
            "isPrimary": True
        },
        "workspaces": [{
            "id": f"00000000-0000-4000-8000-000000000{ordinal + 100}",
            "cwd": "/prototypes/ambiguous-bot",
            "isPrimary": True
        }]
    })
with open(path, "w", encoding="utf-8") as stream:
    json.dump(state, stream)
    stream.write("\n")
PY
stop_fixture
start_fixture
export PAPERCLIP_API_URL="http://127.0.0.1:$PORT"
export PAPERCLIP_API_KEY="$TOKEN"
before_prototype_ambiguous_issues="$(jq '.issues | length' "$STATE")"
PROTOTYPE_AMBIGUOUS_ERR="$TMPDIR/prototype-ambiguous.err"
if printf 'Prototype: ambiguous-bot\nLane: prototype\n' |
  "$CLI" prototype-ticket create --name ambiguous-bot --title ambiguous \
  >/dev/null 2>"$PROTOTYPE_AMBIGUOUS_ERR"; then
  bad "ambiguous prototype projects fail closed"
else
  ok "ambiguous prototype projects fail closed"
fi
assert_contains "prototype ambiguity lists first project" "00000000-0000-4000-8000-000000000123" "$(cat "$PROTOTYPE_AMBIGUOUS_ERR")"
assert_eq "ambiguous prototype creates no issue" "$before_prototype_ambiguous_issues" "$(jq '.issues | length' "$STATE")"

stop_fixture
cat >"$STATE" <<'JSON'
{
  "experimental": {"enableIsolatedWorkspaces": false},
  "company": {"id": "00000000-0000-4000-8000-000000000001", "name": "Fixture"},
  "agents": [{"id": "00000000-0000-4000-8000-000000000010", "name": "Prototyper", "role": "prototyper", "status": "idle"}],
  "projects": [{
    "id": "00000000-0000-4000-8000-000000000131",
    "name": "recipe-bot-2",
    "primaryWorkspace": {"id": "00000000-0000-4000-8000-000000000231", "cwd": "/prototypes/recipe-bot-2", "isPrimary": true},
    "workspaces": [{"id": "00000000-0000-4000-8000-000000000231", "cwd": "/prototypes/recipe-bot-2", "isPrimary": true}]
  }],
  "issues": []
}
JSON
start_fixture
export PAPERCLIP_API_URL="http://127.0.0.1:$PORT"
export PAPERCLIP_API_KEY="$TOKEN"
printf 'Prototype: recipe-bot\nLane: prototype\n' |
  "$CLI" prototype-ticket create --name recipe-bot --title 'Near miss isolated' >"$TMPDIR/prototype-near-miss.json"
assert_eq "isolated near-miss has no project" "null" \
  "$(jq -r '.projectId // null' "$TMPDIR/prototype-near-miss.json")"

stop_fixture
python3 - "$STATE" <<'PY'
import json
import sys
path = sys.argv[1]
issues = [
    {"id": f"00000000-0000-4000-8000-{index:012x}", "identifier": f"FIX-{index}", "title": "filler", "description": "filler", "status": "todo"}
    for index in range(1, 501)
]
issues.append({
    "id": "00000000-0000-4000-8000-00000000abcd",
    "identifier": "FIX-501",
    "title": "beyond first page",
    "description": "Prototype: paged-bot\nLane: prototype\n",
    "status": "todo",
})
state = {
    "experimental": {"enableIsolatedWorkspaces": False},
    "company": {"id": "00000000-0000-4000-8000-000000000001", "name": "Fixture"},
    "agents": [{"id": "00000000-0000-4000-8000-000000000010", "name": "Prototyper", "role": "prototyper", "status": "idle"}],
    "projects": [],
    "issues": issues,
}
with open(path, "w", encoding="utf-8") as stream:
    json.dump(state, stream)
    stream.write("\n")
PY
start_fixture
export PAPERCLIP_API_URL="http://127.0.0.1:$PORT"
export PAPERCLIP_API_KEY="$TOKEN"
printf 'Prototype: paged-bot\nLane: prototype\n' |
  "$CLI" prototype-ticket create --name paged-bot --title 'Paged marker' >"$TMPDIR/prototype-paged.json"
assert_eq "prototype dedupe walks issue pages" "00000000-0000-4000-8000-00000000abcd" \
  "$(jq -r '.id' "$TMPDIR/prototype-paged.json")"
assert_eq "paged dedupe does not create issue" "501" "$(jq '.issues | length' "$STATE")"

stop_fixture
cat >"$STATE" <<'JSON'
{
  "experimental": {"enableIsolatedWorkspaces": false},
  "company": {"id": "00000000-0000-4000-8000-000000000001", "name": "Fixture"},
  "agents": [{"id": "00000000-0000-4000-8000-000000000010", "name": "Prototyper", "role": "prototyper", "status": "idle"}],
  "projects": [],
  "issues": []
}
JSON
start_fixture
export PAPERCLIP_API_URL="http://127.0.0.1:$PORT"
export PAPERCLIP_API_KEY="$TOKEN"
(printf 'Prototype: concurrent-bot\nLane: prototype\n' |
  "$CLI" prototype-ticket create --name concurrent-bot --title 'Concurrent A' >"$TMPDIR/prototype-concurrent-a.json") &
prototype_pid_a=$!
(printf 'Prototype: concurrent-bot\nLane: prototype\n' |
  "$CLI" prototype-ticket create --name concurrent-bot --title 'Concurrent B' >"$TMPDIR/prototype-concurrent-b.json") &
prototype_pid_b=$!
prototype_status_a=0; prototype_status_b=0
wait "$prototype_pid_a" || prototype_status_a=$?
wait "$prototype_pid_b" || prototype_status_b=$?
assert_eq "concurrent prototype helper A succeeds" "0" "$prototype_status_a"
assert_eq "concurrent prototype helper B succeeds" "0" "$prototype_status_b"
assert_eq "idempotent concurrent first ticket count" "1" "$(jq '.issues | length' "$STATE")"
assert_eq "idempotent concurrent helper IDs match" \
  "$(jq -r '.id' "$TMPDIR/prototype-concurrent-a.json")" \
  "$(jq -r '.id' "$TMPDIR/prototype-concurrent-b.json")"
stop_fixture
cat >"$STATE" <<JSON
{
  "experimental": {"enableIsolatedWorkspaces": false},
  "company": {"id": "00000000-0000-4000-8000-000000000001", "name": "Fixture"},
  "agents": [{"id": "00000000-0000-4000-8000-000000000010", "name": "Prototyper", "role": "prototyper", "status": "idle"}],
  "projects": [],
  "issues": [
    {
      "id": "00000000-0000-4000-8000-00000000dead",
      "identifier": "FIX-900",
      "title": "Old terminal",
      "description": "Prototype: terminal-bot\nLane: prototype\n",
      "status": "done",
      "idempotencyKey": "opc-prototype-first:00000000-0000-4000-8000-000000000001:terminal-bot"
    },
    {
      "id": "00000000-0000-4000-8000-00000000stale",
      "identifier": "FIX-901",
      "title": "Prototype: terminal-bot",
      "description": "stale same-scope title",
      "status": "todo",
      "createdAt": "2020-01-01T00:00:00+00:00"
    },
    {
      "id": "00000000-0000-4000-8000-00000000parent",
      "identifier": "FIX-902",
      "title": "Prototype: terminal-bot",
      "description": "different parent title",
      "status": "todo",
      "parentId": "other-parent",
      "createdAt": "2030-01-01T00:00:00+00:00"
    },
    {
      "id": "00000000-0000-4000-8000-00000000fresh",
      "identifier": "FIX-903",
      "assigneeAgentId": "00000000-0000-4000-8000-000000000010",
      "title": "Prototype: terminal-bot",
      "description": "fresh same-scope title",
      "status": "todo",
      "createdAt": "$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%S+00:00')"
    }
  ]
}
JSON
start_fixture
export PAPERCLIP_API_URL="http://127.0.0.1:$PORT"
export PAPERCLIP_API_KEY="$TOKEN"
printf 'Prototype: terminal-bot\nLane: prototype\n' |
  "$CLI" prototype-ticket create --name terminal-bot --title 'Retry epoch' >"$TMPDIR/prototype-terminal-retry.json"
assert_not_contains "terminal retry does not replay old issue" "00000000-0000-4000-8000-00000000dead" \
  "$(jq -r '.id' "$TMPDIR/prototype-terminal-retry.json")"
assert_eq "terminal retry ignores stale and different-parent titles" "00000000-0000-4000-8000-00000000fresh" \
  "$(jq -r '.id' "$TMPDIR/prototype-terminal-retry.json")"
assert_eq "terminal retry leaves title candidates unchanged" "4" "$(jq '.issues | length' "$STATE")"
assert_eq "terminal retry is non-terminal" "todo" "$(jq -r '.issues[3].status' "$STATE")"
assert_eq "terminal retry uses stable title" "Prototype: terminal-bot" "$(jq -r '.issues[3].title' "$STATE")"
assert_eq "terminal retry omits old idempotency key" "null" "$(jq -r '.issues[3].idempotencyKey // null' "$STATE")"
stop_fixture
cat >"$STATE" <<'JSON'
{
  "experimental": {"enableIsolatedWorkspaces": false},
  "company": {"id": "00000000-0000-4000-8000-000000000001", "name": "Fixture"},
  "agents": [{"id": "00000000-0000-4000-8000-000000000010", "name": "Prototyper", "role": "prototyper", "status": "idle"}],
  "projects": [],
  "issues": [{
    "id": "00000000-0000-4000-8000-00000000dead",
    "identifier": "FIX-900",
    "title": "Old terminal",
    "description": "Prototype: terminal-race\nLane: prototype\n",
    "status": "cancelled",
    "idempotencyKey": "opc-prototype-first:00000000-0000-4000-8000-000000000001:terminal-race"
  }]
}
JSON
start_fixture
export PAPERCLIP_API_URL="http://127.0.0.1:$PORT"
export PAPERCLIP_API_KEY="$TOKEN"
(printf 'Prototype: terminal-race\nLane: prototype\n' |
  "$CLI" prototype-ticket create --name terminal-race --title 'Race A' >"$TMPDIR/prototype-terminal-race-a.json") &
terminal_race_pid_a=$!
(printf 'Prototype: terminal-race\nLane: prototype\n' |
  "$CLI" prototype-ticket create --name terminal-race --title 'Race B' >"$TMPDIR/prototype-terminal-race-b.json") &
terminal_race_pid_b=$!
terminal_race_status_a=0; terminal_race_status_b=0
wait "$terminal_race_pid_a" || terminal_race_status_a=$?
wait "$terminal_race_pid_b" || terminal_race_status_b=$?
assert_eq "concurrent terminal retry A succeeds" "0" "$terminal_race_status_a"
assert_eq "concurrent terminal retry B succeeds" "0" "$terminal_race_status_b"
assert_eq "concurrent terminal retry count" "2" "$(jq '.issues | length' "$STATE")"
assert_eq "concurrent terminal retry IDs match" \
  "$(jq -r '.id' "$TMPDIR/prototype-terminal-race-a.json")" \
  "$(jq -r '.id' "$TMPDIR/prototype-terminal-race-b.json")"
assert_contains "prototype ambiguity lists second project" "00000000-0000-4000-8000-000000000124" "$(cat "$PROTOTYPE_AMBIGUOUS_ERR")"
cleanup
TMPDIR=""
if [ "$RUN_LIVE_AFTER_FIXTURE" -eq 1 ] && docker compose ps >/dev/null 2>&1; then
  echo "── live routing gate ──"
  live_gate
  live_status=$?
  live_cleanup
  cleanup_status=$?
  trap - EXIT INT TERM
  [ "$live_status" -eq 0 ] && [ "$cleanup_status" -eq 0 ] || FAIL=$((FAIL+1))
fi
echo "result: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
