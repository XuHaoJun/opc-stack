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

# Fix round 1 stopped the wrapper's old home-root fallback from handing the
# chief of staff's key to hermes-dashboard, but nothing asserted the negative
# case. In hermes-dashboard, /opt/data is bound to frontdoor-hermes, so the
# chief of staff's key genuinely sits at /opt/data/.agent.nsec (precondition
# asserted below, else this check would be vacuous) — with THIS container's
# own unscoped HERMES_HOME=/opt/data, the wrapper must still resolve no
# identity.
#
# Fix round 3 (review finding 1): this used to assert "buzz exits 3", on the
# theory that a missing key makes the CLI refuse locally before any network
# call. But upstream/buzz/crates/buzz-cli/src/error.rs:87-104 maps a relay
# 401/403 to the SAME exit code 3 — the check only discriminated because this
# container happens to have no reachable BUZZ_RELAY_URL, so a LEAKED key
# would instead fail on the network with exit 2. That is incidental, not the
# property we care about, and a later change to give hermes-dashboard a
# working relay URL would make a real leak pass green. Assert the property
# directly instead: run the wrapper's own resolution logic — with its final
# `exec` line stripped off and replaced with something that prints
# $BUZZ_PRIVATE_KEY — and require the result to be empty. This never invokes
# the real buzz binary (no network involved) and is blind to how many exit
# codes the CLI happens to share.
check "dashboard wrapper resolves to NO identity (chief of staff's key must stay unreachable)" \
    docker compose exec -T -u 10000 -e HOME=/opt/data -e HERMES_HOME=/opt/data hermes-dashboard sh -c "
        test -s /opt/data/.agent.nsec || exit 9
        unset BUZZ_PRIVATE_KEY
        got=\$(sed '\$d' /usr/local/bin/buzz | { cat; printf '%s\n' 'printf \"%s\" \"\$BUZZ_PRIVATE_KEY\"'; } | sh)
        [ -z \"\$got\" ]
    "

echo "── identity & memory ──"
checkout "profile SOUL.md is the scientist's, not the front door's" "scientist" \
    docker compose exec -T hermes head -5 "/opt/data/profiles/$PROFILE/SOUL.md"
# A bare `! cmp -s scientist chief` is vacuous here: before the sync in
# opc_seed_expert_profile exists, hermes has already written its own generic
# built-in identity into a freshly-created profile home, and that generic
# text already differs from the chief of staff's fully-custom SOUL.md — so
# the bare comparison would pass whether or not this task's sync code ever
# ran. Grepping for hermes's built-in wording would fix that but pin the
# check's falsifiability to an upstream string: a reworded default silently
# returns it to the vacuous form. Assert the two properties positively
# instead, with no upstream literal — the boot sync actually ran (the
# profile's copy is byte-identical to the image copy the entrypoint syncs
# from) AND the result is not the chief of staff's file (the regression the
# comparison was meant to catch).
check "profile SOUL.md is the image's synced copy, not the chief of staff's" \
    docker compose exec -T hermes sh -c "cmp -s /opt/data/profiles/$PROFILE/SOUL.md /opt/hermes/profiles/$PROFILE/SOUL.md && ! cmp -s /opt/data/profiles/$PROFILE/SOUL.md /opt/data/SOUL.md"
check "no process-wide MEMORY_TENCENTDB_AGENT_ID on the gateway" \
    docker compose exec -T hermes sh -c '! env | grep -q ^MEMORY_TENCENTDB_AGENT_ID='
# Both cron checks list with --all. `cron list` alone is
# list_jobs(include_disabled=False) (hermes_cli/cron.py:99-103) and `cron
# pause` sets enabled:False (cron/jobs.py::pause_job), so a paused job is
# invisible to a default listing — which is exactly the state in which the
# entrypoint's guard used to create a second, active copy. A gate that also
# looks away cannot see that happen.
checkout "autonomous experiment queue is scheduled" "experiment-queue" \
    docker compose exec -T -e HERMES_HOME="/opt/data/profiles/$PROFILE" hermes /opt/hermes/bin/hermes cron list --all
check "the cron job was not duplicated across boots" \
    docker compose exec -T -e HERMES_HOME="/opt/data/profiles/$PROFILE" hermes sh -c "test \"\$(/opt/hermes/bin/hermes cron list --all 2>/dev/null | grep -c experiment-queue)\" -eq 1"
# Credentials are injected into THIS exec only (opc_load_env already read
# them from ./.env). They are deliberately NOT added to the tencentdb-core
# service's compose environment: that would put the admin user key in the
# long-running container's /proc/1/environ, in every child process and in
# `docker inspect`, permanently, so that a test could read it conveniently.
checkout "tencentdb knows the scientist agent" '"agent_id"' \
    docker compose exec -T \
        -e OPC_TDAI_API_KEY="${TENCENTDB_GATEWAY_API_KEY:-}" \
        -e OPC_TDAI_USER_KEY="${TENCENTDB_ADMIN_USER_KEY:-}" \
        tencentdb-core sh -c "curl -sS -X POST http://127.0.0.1:8420/v3/meta/agent/get -H 'Content-Type: application/json' -H 'x-tdai-service-id: default' -H \"Authorization: Bearer \$OPC_TDAI_API_KEY\" -H \"x-tdai-user-key: \$OPC_TDAI_USER_KEY\" -d '{\"agent_id\":\"$PROFILE\"}'"

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
