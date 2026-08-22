#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
PASS=0 FAIL=0
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
assert_eq() { local label="$1" want="$2" got="$3"; [ "$want" = "$got" ] && ok "$label" || { bad "$label (want=$want got=$got)"; return 1; }; }
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
for invalid_repo in 'https://gitlab.com/owner/repo' 'git@evil:owner/repo' '/tmp/repo' 'Owner/' 'Owner/Repo/'; do
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
PORT="${PAPERCLIP_FIXTURE_PORT:-$((39000 + ($$ % 1000)))}"
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
  bad "fixture starts on caller-supplied loopback port"
  return 1
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
    "runtimeConfig": {"heartbeat": {"maxConcurrentRuns": 4, "fixtureKeep": true}},
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
  assert_eq "show preserves workspace metadata" "kept" "$(printf '%s' "$SHOW" | jq -r .workspace.metadata.fixture)"
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
for invalid_max in 0 51; do
  before="$(cat "$STATE")"
  if $CLI agent concurrency set --role engineer --max "$invalid_max" >/dev/null 2>&1; then
    bad "concurrency rejects max $invalid_max"
  else
    ok "concurrency rejects max $invalid_max"
  fi
  assert_eq "invalid max $invalid_max does not PATCH" "$before" "$(cat "$STATE")"
done

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
start_fixture
export PAPERCLIP_API_URL="http://127.0.0.1:$PORT"
export PAPERCLIP_API_KEY="$TOKEN"
"$CLI" project workspace set --repo Owner/Repo --mode shared_workspace \
  --shared-concurrency serialize --strategy project_primary >/dev/null
assert_eq "workspace set preserves last-applied marker" "isolated_workspace" \
  "$(jq -r '.projects[0].primaryWorkspace.metadata.opcWorkspaceDefaults.mode' "$STATE")"
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

echo "result: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
