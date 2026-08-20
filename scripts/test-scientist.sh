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
#
# An EMPTY want is always a bug, never a check: `grep -qF -- ""` matches any
# output at all, including the error text of a command that did not run. Three
# vacuous checks have landed in this repo that way (one of them in this very
# file — a wanted substring built from a `docker compose exec ... cat` that
# failed silently and expanded to nothing). Fail loudly instead of passing.
checkout() {
    local label="$1" want="$2"; shift 2
    if [ -z "$want" ]; then
        fail "$label (BUG: empty wanted-substring — this check would match anything)"
        return
    fi
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

echo "── gateway multiplex ──"
checkout "multiplex is on" "GATEWAY_MULTIPLEX_PROFILES=1" \
    docker compose exec -T hermes sh -c 'env | grep ^GATEWAY_MULTIPLEX_PROFILES='
# NOT a bare `/p/<profile>/v1/health -> 200` check: with multiplex OFF the
# /p/ prefix is ignored entirely (api_server._resolve_request_profile), so
# that route already 200s as the default profile and the check would pass
# before any of this is implemented. What distinguishes a real profile route
# is WHOSE credential it accepts, so assert that instead.
check "profile route serves 200 with the PROFILE's own key" \
    docker compose exec -T hermes sh -c "k=\$(sed -n 's/^API_SERVER_KEY=//p' /opt/data/profiles/$PROFILE/.env 2>/dev/null); test -n \"\$k\" && test \"\$(curl -sS -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer \$k\" http://127.0.0.1:8642/p/$PROFILE/v1/models)\" = 200"
check "profile route REJECTS the default profile's key" \
    docker compose exec -T hermes sh -c "test \"\$(curl -sS -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer \$API_SERVER_KEY\" http://127.0.0.1:8642/p/$PROFILE/v1/models)\" = 401"
check "unknown profile -> 404" \
    docker compose exec -T hermes sh -c "test \"\$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8642/p/no-such-expert/v1/health)\" = 404"
check "profile home exists" \
    docker compose exec -T hermes test -f "/opt/data/profiles/$PROFILE/config.yaml"
check "profile .env carries an API_SERVER_KEY >=16 chars" \
    docker compose exec -T hermes sh -c "test \"\$(sed -n 's/^API_SERVER_KEY=//p' /opt/data/profiles/$PROFILE/.env | head -1 | wc -c)\" -ge 17"
checkout "dashboard switcher lists the profile" "$PROFILE" \
    docker compose exec -T -u 10000 -e HOME=/opt/data -e HERMES_HOME=/opt/data hermes-dashboard /opt/hermes/bin/hermes profile list

echo "── buzz identity ──"
check "scientist keypair exists" \
    docker compose exec -T hermes sh -c 'test -s /keys/scientist.nsec && test -s /keys/scientist.pub'
check "buzz CLI present in the hermes image" \
    docker compose exec -T hermes test -x /usr/local/bin/buzz.bin
checkout "buzz wrapper injects the profile identity" "BUZZ_PRIVATE_KEY" \
    docker compose exec -T hermes cat /usr/local/bin/buzz
check "profile carries its own nsec (not the chief of staff's)" \
    docker compose exec -T hermes sh -c "test -s /opt/data/profiles/$PROFILE/.agent.nsec && ! cmp -s /opt/data/profiles/$PROFILE/.agent.nsec /keys/agent.nsec"
check "agent uid can read its nsec" \
    docker compose exec -T -u 10000 hermes sh -c "test -r /opt/data/profiles/$PROFILE/.agent.nsec"
checkout "scientist is a relay member" '"channel_id"' \
    docker compose exec -T -u 10000 -e HERMES_HOME=/opt/data/profiles/agt-scientist hermes sh -c 'buzz --relay "http://$(printf "%s" "$BUZZ_RELAY_URL" | sed "s#^wss\?://##")" channels list --member'

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
