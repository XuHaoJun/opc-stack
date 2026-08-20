#!/usr/bin/env bash
# Scientist expert lane — end-to-end gate.
#
# Grows task-by-task alongside docs/superpowers/plans/2026-08-20-scientist-expert-profile.md.
# Run from the repo root against a running stack: scripts/test-scientist.sh
#
# This repo has no unit-test framework; every check here is "run a command,
# compare the output". Checks are ordered by layer (volume -> gateway ->
# identity -> board) so the first failure tells you which layer broke.
set -uo pipefail
cd "$(dirname "$0")/.."

PROFILE="agt-scientist"
PASS=0
FAIL=0

pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

# check <label> <cmd...> — pass when the command exits 0.
check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}

# checkout <label> <expected-substring> <cmd...> — pass when stdout contains it.
checkout() {
    local label="$1" want="$2"; shift 2
    local got
    got="$("$@" 2>&1)"
    if printf '%s' "$got" | grep -qF -- "$want"; then
        pass "$label"
    else
        fail "$label (wanted substring: $want)"
        printf '      got: %s\n' "$(printf '%s' "$got" | head -3)"
    fi
}

echo "── volumes ──"
checkout "hermes mounts /opt/data/profiles" "/opt/data/profiles" \
    docker compose exec -T hermes sh -c 'mount | grep " /opt/data/profiles "'
checkout "dashboard mounts /opt/data/profiles" "/opt/data/profiles" \
    docker compose exec -T hermes-dashboard sh -c 'mount | grep " /opt/data/profiles "'

echo "── dashboard ──"
check "dashboard 9119 responds" \
    sh -c 'code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:9119/); [ "$code" = "200" ] || [ "$code" = "401" ] || [ "$code" = "302" ]'
if docker compose logs --since 10m hermes-dashboard 2>&1 | grep -q "Resource busy"; then
    fail "dashboard has no flock storm (found 'Resource busy')"
else
    pass "dashboard has no flock storm"
fi

echo
printf 'result: %d pass, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
