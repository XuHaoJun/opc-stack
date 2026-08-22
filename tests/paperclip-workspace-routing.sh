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
  "agents": [],
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

echo "result: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
