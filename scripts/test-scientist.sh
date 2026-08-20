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
. "$(dirname "$0")/load-env.sh"; opc_load_env ./.env

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
# The real gate: call upstream's own role detector inside the live container,
# against its live /proc/1-derived argv — not docker-compose.yml. Reverting
# `command` back to `sleep infinity` makes _read_container_argv() find
# "sleep"/"infinity" after the main-wrapper.sh token instead of "dashboard",
# so _is_dashboard_container() returns False and this check goes red. See
# upstream/hermes/hermes_cli/container_boot.py:298-371 (_strip_container_argv_prefix
# peels the s6/main-wrapper.sh launcher prefix and an optional leading
# `hermes`, then _is_dashboard_container requires args[0] == "dashboard").
checkout "dashboard container argv resolves to dashboard role" "True" \
    docker compose exec -T hermes-dashboard /opt/hermes/.venv/bin/python3 -c \
    'from hermes_cli.container_boot import _read_container_argv, _is_dashboard_container as f; print(f(_read_container_argv()))'

check "dashboard ${HERMES_DASHBOARD_PORT:-9119} responds" \
    sh -c 'code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${HERMES_DASHBOARD_PORT:-9119}/"); [ "$code" = "200" ] || [ "$code" = "401" ] || [ "$code" = "302" ]'
if docker compose logs --since 10m hermes-dashboard 2>&1 | grep -q "Resource busy"; then
    fail "dashboard has no flock storm (found 'Resource busy')"
else
    pass "dashboard has no flock storm"
fi

echo
printf 'result: %d pass, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
