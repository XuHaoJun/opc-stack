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
    "id": "project-1",
    "name": "Display Name Is Not Identity",
    "executionWorkspacePolicy": {"defaultMode": "isolated_workspace", "workspaceStrategy": {"type": "git_worktree"}},
    "primaryWorkspace": {
      "id": "workspace-1",
      "repoUrl": "ssh://git@github.com/Owner/Repo.git",
      "isPrimary": true,
      "metadata": {"fixture": "kept"}
    },
    "workspaces": [{
      "id": "workspace-1",
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
  assert_eq "show project id" "project-1" "$(printf '%s' "$SHOW" | jq -r .project.id)"
  assert_eq "show project display name" "Display Name Is Not Identity" "$(printf '%s' "$SHOW" | jq -r .project.name)"
  assert_eq "show workspace id" "workspace-1" "$(printf '%s' "$SHOW" | jq -r .workspace.id)"
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
  "agents": [],
  "projects": [{
    "id": "project-ambiguous",
    "name": "Ambiguous",
    "workspaces": [
      {"id": "workspace-a", "repoUrl": "https://github.com/owner/repo", "isPrimary": true},
      {"id": "workspace-b", "repoUrl": "https://github.com/owner/repo/", "isPrimary": true}
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
      "id": "project-a",

      "name": "Alpha",
      "workspaces": [
        {"id": "workspace-a", "repoUrl": "https://github.com/owner/repo", "isPrimary": true}
      ]
    },
    {
      "id": "project-b",
      "name": "Beta",
      "workspaces": [
        {"id": "workspace-b", "repoUrl": "ssh://git@github.com/owner/repo.git", "isPrimary": true}
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
assert_contains "duplicate error includes first project ID/name" "project-a Alpha" "$(cat "$DUPLICATE_ERR")"
assert_contains "duplicate error includes second project ID/name" "project-b Beta" "$(cat "$DUPLICATE_ERR")"
assert_not_contains "duplicate stderr omits bearer token" "$TOKEN" "$(cat "$DUPLICATE_ERR")"
assert_not_contains "duplicate fixture log omits bearer token" "$TOKEN" "$(cat "$LOG")"
stop_fixture
cat >"$STATE" <<'JSON'
{
  "experimental": {"enableIsolatedWorkspaces": false},
  "company": {"id": "00000000-0000-4000-8000-000000000001", "name": "Fixture"},
  "agents": [
    {"id": "engineer-a", "name": "Engineer A", "role": "engineer"},
    {"id": "engineer-b", "name": "Engineer B", "role": "engineer"}
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
