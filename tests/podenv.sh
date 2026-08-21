#!/usr/bin/env bash
# podenv lane — 結構 + live gate。
#
# 從 repo root 對著跑著的 stack 執行: tests/podenv.sh
#
# 與 tests/scientist.sh 同慣例: 沒有 unit-test framework, 每條檢查都是「跑一個
# 指令、比對輸出」。順序是先結構後 live, 所以第一個失敗就告訴你是哪一層壞的 ——
# 結構檢查不需要 stack 在跑, live 檢查需要。
set -uo pipefail
cd "$(dirname "$0")/.."
. "$(dirname "$0")/../scripts/load-env.sh"; opc_load_env ./.env

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}
# expect <label> <expected> <cmd...> — pass when stdout trims to <expected>.
# NOTE: this only compares stdout, not the command's exit status — empty
# stdout (e.g. because the command itself failed to run) reads the same as a
# legitimately empty result. Fine for checks whose failure mode changes what
# they PRINT (podenv_field below turns a missing service into a sentinel that
# cannot match any expected value); use expect_ok instead when the command
# can fail silently with empty stdout (docker compose exec against a stopped
# container prints its error to stderr and exits non-zero with empty stdout).
expect() {
    local label="$1" want="$2"; shift 2
    local got
    got="$("$@" 2>/dev/null | tr -d '\r' | tail -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ "$got" = "$want" ]; then pass "$label"; else fail "$label (want '$want', got '$got')"; fi
}
# expect_ok <label> <expected> <cmd...> — like expect(), but ALSO requires the
# command itself to have exited 0. Without this, "could not run the check"
# (e.g. `docker compose exec` against a stopped container) is indistinguishable
# from "ran fine and printed nothing" — both give empty stdout.
expect_ok() {
    local label="$1" want="$2"; shift 2
    local got rc
    got="$("$@" 2>/dev/null)"; rc=$?
    got="$(printf '%s' "$got" | tr -d '\r' | tail -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
        pass "$label"
    else
        fail "$label (want '$want', got '$got', exit $rc)"
    fi
}

echo "── structure ──"

# The whole security posture of this lane is three compose declarations and
# nothing else. Reading the RESOLVED config (not the file) is deliberate: an
# override file or an env default could add a fourth without touching
# docker-compose.yml.
CONF_JSON="$(docker compose config --format json 2>/dev/null)"
# On a KeyError (most commonly: the `podenv` service does not exist in the
# resolved config at all) this must NOT fall through to empty stdout — empty
# is also the correct, PASSING value for several of the checks below (no bind
# mount, no secret volume). Emit a sentinel that cannot match any expected
# value instead, so "the service is missing" fails loudly rather than reading
# as "the service exists and rightfully has nothing to report."
podenv_field() {
    local out rc
    out="$(printf '%s' "$CONF_JSON" | python3 -c "$1" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ]; then printf 'PODENV_SERVICE_MISSING\n'; else printf '%s\n' "$out"; fi
}

expect "security_opt is exactly [seccomp=unconfined]" "seccomp=unconfined" \
    podenv_field 'import json,sys; print(",".join(json.load(sys.stdin)["services"]["podenv"].get("security_opt",[])))'
expect "devices is exactly [/dev/net/tun]" "/dev/net/tun" \
    podenv_field 'import json,sys
s=json.load(sys.stdin)["services"]["podenv"]
d=s.get("devices",[])
print(",".join(x if isinstance(x,str) else x.get("source","?") for x in d))'
expect "not privileged" "False" \
    podenv_field 'import json,sys; print(json.load(sys.stdin)["services"]["podenv"].get("privileged",False))'
expect "no host bind mount" "" \
    podenv_field 'import json,sys
s=json.load(sys.stdin)["services"]["podenv"]
print(",".join(v.get("source","") for v in s.get("volumes",[]) if v.get("type")=="bind"))'
expect "mounts no secret volume" "" \
    podenv_field 'import json,sys
bad={"opc-keys","opc-gh-creds","opc-prototyper-home","frontdoor-hermes","hermes-profiles","hermes-data"}
s=json.load(sys.stdin)["services"]["podenv"]
print(",".join(sorted({v.get("source","") for v in s.get("volumes",[])} & bad)))'
expect "port range is published on 127.0.0.1 only" "127.0.0.1" \
    podenv_field 'import json,sys
s=json.load(sys.stdin)["services"]["podenv"]
print(",".join(sorted({p.get("host_ip","") for p in s.get("ports",[])})))'

# compose cannot do arithmetic, so the pool bounds are stated twice. The same
# hazard is already documented for DEVENV_HTTP_PORT_RANGE_END.
BASE="${PODENV_PORT_BASE:-23000}"; COUNT="${PODENV_PORT_COUNT:-16}"
END="${PODENV_PORT_RANGE_END:-23015}"
expect "PODENV_PORT_RANGE_END == BASE + COUNT - 1" "$((BASE + COUNT - 1))" echo "$END"
check "port base is below the ephemeral range" test "$BASE" -lt 32768

echo "── live ──"

check "podenv container is running" \
    sh -c 'docker compose ps --format "{{.Service}} {{.State}}" | grep -q "^podenv running$"'
# `test -S` only proves the socket FILE exists — measured: a stale socket left
# over from a previous run (still present on the persistent volume) also
# passes `test -S` with nobody listening. Prove the API actually answers,
# as the uid that will use it (there is no curl in this image; podman itself
# is the client).
check "podman API answers on the socket" \
    docker compose exec -T -u 1000 -e HOME=/home/podman -e XDG_RUNTIME_DIR=/run/user/1000 podenv \
    podman --remote --url unix:///run/podenv/podman.sock version
# NOT `expect` with a precomputed "want": both sides here come from a command
# (paperclip's node uid, podenv's socket owner), and if EITHER command fails
# outright (e.g. paperclip is down), it prints nothing — the same empty
# string a legitimately-matching value could never be, but indistinguishable
# from "compared two empty strings and called it a match" once you're only
# looking at stdout. That's the exact defect class expect_ok was introduced
# to close, generalized to two commands instead of one: require BOTH exit 0
# AND agree, not just agree.
_node_uid="$(docker compose exec -T paperclip id -u node 2>/dev/null)"; _node_rc=$?
_node_uid="$(printf '%s' "$_node_uid" | tr -d '\r')"
_sock_uid="$(docker compose exec -T podenv stat -c %u /run/podenv/podman.sock 2>/dev/null)"; _sock_rc=$?
_sock_uid="$(printf '%s' "$_sock_uid" | tr -d '\r')"
if [ "$_node_rc" -eq 0 ] && [ "$_sock_rc" -eq 0 ] && [ -n "$_node_uid" ] && [ "$_node_uid" = "$_sock_uid" ]; then
    pass "socket owner uid == paperclip node uid"
else
    fail "socket owner uid == paperclip node uid (want '$_node_uid' [rc=$_node_rc], got '$_sock_uid' [rc=$_sock_rc])"
fi
expect_ok "self-test left no diagnosis" "" \
    docker compose exec -T podenv cat /run/podenv/diagnosis
expect "nested podman run works" "NESTED_OK" \
    docker compose exec -T -u 1000 -e HOME=/home/podman -e XDG_RUNTIME_DIR=/run/user/1000 podenv \
    podman run --rm docker.io/library/alpine:3.20 echo NESTED_OK
expect "default netns is pasta, not the upstream host" "pasta" \
    docker compose exec -T -u 1000 -e HOME=/home/podman -e XDG_RUNTIME_DIR=/run/user/1000 podenv \
    sh -c 'podman run -d --name podenv-netns-probe docker.io/library/alpine:3.20 sleep 30 >/dev/null 2>&1
           podman inspect podenv-netns-probe --format "{{.HostConfig.NetworkMode}}"
           podman rm -f podenv-netns-probe >/dev/null 2>&1'
# userns must stay host: dropping it moves nested-created files into the subuid
# range and /prototypes replays the invariant-3b ownership pain.
expect "userns stays host (file ownership on /prototypes)" "1000" \
    docker compose exec -T -u 1000 -e HOME=/home/podman -e XDG_RUNTIME_DIR=/run/user/1000 podenv \
    sh -c 'podman run --rm -v /prototypes:/p docker.io/library/alpine:3.20 \
             sh -c "touch /p/.podenv-probe" >/dev/null 2>&1
           stat -c %u /prototypes/.podenv-probe; rm -f /prototypes/.podenv-probe'
# podman is PID 1 inside the container and never wait()s on reparented
# children — every nested `podman run` leaves a (pasta.avx2) and a (conmon)
# zombie behind (measured: 5 nested runs -> 10 zombies, ppid 1). init: true
# (docker-init as the real PID 1) is what reaps them. No `ps` in this image,
# so read /proc/*/stat directly — field 3 is the state char, `Z` = zombie.
check "no zombie processes after nested container runs" \
    sh -c '
        for i in 1 2; do
            docker compose exec -T -u 1000 -e HOME=/home/podman -e XDG_RUNTIME_DIR=/run/user/1000 podenv \
                podman run --rm docker.io/library/alpine:3.20 true >/dev/null 2>&1
        done
        z="$(docker compose exec -T podenv sh -c "
            z=0
            for f in /proc/[0-9]*/stat; do
                set -- \$(cat \"\$f\" 2>/dev/null)
                if [ \"\$3\" = \"Z\" ]; then z=\$((z + 1)); fi
            done
            echo \"\$z\"
        " 2>/dev/null | tr -d "\r")"
        [ "${z:-1}" -eq 0 ]
    '
# mem_limit is the ONLY memory knob that works (spec measurement 4). Read
# podenv's OWN cgroup file — the nested one is always `max`, so asserting
# there would make this check green in the wrong place.
check "mem_limit is actually applied to the podenv container" \
    sh -c 'v=$(docker compose exec -T podenv cat /sys/fs/cgroup/memory.max 2>/dev/null | tr -d "\r"); [ -n "$v" ] && [ "$v" != "max" ]'

echo "── cli ──"

# NOT a version-match check: the client is Debian's podman-remote (5.4.2) and
# the runtime host is 5.8.4, and that gap is measured to be fine — `version`,
# `run`, `ps`, `build`, `image inspect`, and `system df` all work across it.
# What actually matters is that the client can DRIVE the server, so assert
# that property directly: a non-empty server version AND a real nested
# operation succeeding. expect_ok (not expect) because either half failing
# silently — e.g. the socket unreachable — must not read as a match.
expect_ok "paperclip's podman client can drive the podenv server" "OK" \
    docker compose exec -T -u node paperclip sh -c \
    's=$(podman --remote version --format "{{.Server.Version}}" 2>/dev/null)
     [ -n "$s" ] || exit 1
     podman --remote run --rm docker.io/library/alpine:3.20 echo NESTED_OK >/dev/null 2>&1 || exit 1
     echo OK'
check "podenv list works" docker compose exec -T -u node paperclip podenv list
check "podenv_lease table exists" \
    docker compose exec -T paperclip sh -c \
    'PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" psql -h "$DEVENV_PG_HOST" -U "$DEVENV_PG_ADMIN_USER" \
       -d "${DEVENV_CONTROL_DB:-devenv_control}" -tAc "SELECT 1 FROM podenv_lease LIMIT 1" >/dev/null'
check "devenv list shows the podenv section" \
    sh -c 'docker compose exec -T -u node paperclip devenv list 2>&1 | grep -q "podenv leases"'
expect "bad usage is exit 2" "2" \
    docker compose exec -T -u node paperclip sh -c 'podenv provision 2>/dev/null; echo $?'
# The reserved-name list must have exactly one home. If podenv grew its own
# copy, this drifts silently and two tools write the same .env key.
expect "reserved env names come from devenv, not a second copy" "DATABASE_URL" \
    docker compose exec -T -u node paperclip sh -c \
    '. /usr/local/lib/devenv/shared.sh; devenv_reserved_env_names | grep -x DATABASE_URL'

echo "── podenv_usage partial-state guard ──"

# Review finding F1: opc-podenv-seed.sh applies bootstrap.sql with
# ON_ERROR_STOP=1 but no --single-transaction, so "podenv_lease created,
# podenv_usage failed" is a reachable, persistent partial state. devenv's
# cmd_list guards the podenv section on the object it actually queries
# (podenv_usage), so that state must degrade to a warning, never abort the
# whole listing and take real leases (scientist + 3 prototypes) down with it.
# Drop ONLY the view to create that state — safe, it is derived and the seed
# recreates it below regardless of how this check comes out.
docker compose exec -T paperclip sh -c \
    'PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" psql -h "$DEVENV_PG_HOST" -U "$DEVENV_PG_ADMIN_USER" \
       -d "${DEVENV_CONTROL_DB:-devenv_control}" -c "DROP VIEW IF EXISTS podenv_usage;"' >/dev/null 2>&1

_pu_out="$(docker compose exec -T -u node paperclip devenv list 2>&1)"; _pu_rc=$?
if [ "$_pu_rc" -eq 0 ]; then
    pass "devenv list survives podenv_usage missing (exit 0, not aborted)"
else
    fail "devenv list survives podenv_usage missing (exit 0, not aborted) (got exit $_pu_rc)"
fi
if printf '%s\n' "$_pu_out" | grep -q "podenv_usage"; then
    pass "devenv list names podenv_usage in its warning"
else
    fail "devenv list names podenv_usage in its warning (output: $_pu_out)"
fi
if printf '%s\n' "$_pu_out" | grep -q "scientist"; then
    pass "devenv list still shows the real leases despite the missing view"
else
    fail "devenv list still shows the real leases despite the missing view (output: $_pu_out)"
fi

# Restore via the actual repair path (the idempotent seed), not hand-written
# SQL, so this test also proves that path works.
docker compose exec -T paperclip sh -c \
    '. /usr/local/bin/opc-podenv-seed.sh; opc_podenv_seed_schema' >/dev/null 2>&1
check "devenv list shows the podenv section again after reseeding" \
    sh -c 'docker compose exec -T -u node paperclip devenv list 2>&1 | grep -q "podenv leases"'

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
