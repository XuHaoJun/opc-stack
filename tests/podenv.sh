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

echo "── provision / release ──"

PROBE_ENV=/tmp/podenv-gate.env
docker compose exec -T -u node paperclip sh -c "rm -f $PROBE_ENV" >/dev/null 2>&1

expect "provision writes the requested variable" "WHOAMI_ADDR" \
    docker compose exec -T -u node paperclip sh -c \
    "podenv provision gate-probe --image docker.io/traefik/whoami --port 80 \
        --as WHOAMI_ADDR --env-file $PROBE_ENV >/dev/null 2>&1
     sed 's/=.*//' $PROBE_ENV | grep -x WHOAMI_ADDR"

expect "the lease is reachable from paperclip over docker DNS" "200" \
    docker compose exec -T -u node paperclip sh -c \
    "addr=\$(grep '^WHOAMI_ADDR=' $PROBE_ENV | cut -d= -f2-)
     curl -s -o /dev/null -w '%{http_code}' --max-time 5 \"http://\$addr/\""

# expect_ok, not expect: without the `-n "$a"` guard and the `|| exit 1` on the
# re-run, an EMPTY $a and an EMPTY $b (e.g. because the prior provision never
# actually wrote the file) also satisfy "$a" = "$b" and print "same" — a false
# pass that proves nothing ran, not that it is idempotent. Measured: this is
# exactly what happened against the unimplemented stub.
expect_ok "provision is idempotent (same port on re-run)" "same" \
    docker compose exec -T -u node paperclip sh -c \
    "a=\$(grep '^WHOAMI_ADDR=' $PROBE_ENV | cut -d= -f2-)
     [ -n \"\$a\" ] || exit 1
     podenv provision gate-probe --image docker.io/traefik/whoami --port 80 \
        --as WHOAMI_ADDR --env-file $PROBE_ENV >/dev/null 2>&1 || exit 1
     b=\$(grep '^WHOAMI_ADDR=' $PROBE_ENV | cut -d= -f2-)
     [ \"\$a\" = \"\$b\" ] && echo same || echo \"\$a != \$b\""

# `{{.Labels.opc.podenv.key}}` cannot work — the label name contains dots, so
# Go's template parser reads them as field traversal. `index` is the only way.
expect "the lease carries the restore label" "gate-probe" \
    docker compose exec -T -u node paperclip sh -c \
    'podman ps --filter label=opc.podenv.lease --format "{{index .Labels \"opc.podenv.key\"}}" 2>/dev/null | head -1'

# expect_ok: if provision fails, KEEP_ME was never at risk of being clobbered
# (the file was never touched), so an unguarded check passes for the wrong
# reason. `|| exit 1` on the provision call makes that failure visible instead
# of silently proving nothing.
expect_ok "provision does not clobber other keys in .env" "KEEP_ME" \
    docker compose exec -T -u node paperclip sh -c \
    "echo 'KEEP_ME=yes' >> $PROBE_ENV
     podenv provision gate-probe --image docker.io/traefik/whoami --port 80 \
        --as WHOAMI_ADDR --env-file $PROBE_ENV >/dev/null 2>&1 || exit 1
     sed 's/=.*//' $PROBE_ENV | grep -x KEEP_ME"

# expect_ok, with an explicit precondition: without proving the lease existed
# (nb/rb >= 1) BEFORE release runs, "n=0 and r=0 afterwards" is also true when
# release had nothing to do — e.g. because provision above never actually
# created anything. That precondition failing, or release itself failing, both
# `exit 1` so the command-as-a-whole fails rather than quietly printing "gone".
expect_ok "release removes container and row" "gone" \
    docker compose exec -T -u node paperclip sh -c \
    "nb=\$(podman ps -a --filter label=opc.podenv.lease --format '{{.Names}}' 2>/dev/null | grep -c podenv_gate_probe || true)
     rb=\$(podenv list 2>/dev/null | grep -c gate-probe || true)
     [ \"\$nb\" -ge 1 ] && [ \"\$rb\" -ge 1 ] || exit 1
     podenv release gate-probe >/dev/null 2>&1 || exit 1
     n=\$(podman ps -a --filter label=opc.podenv.lease --format '{{.Names}}' 2>/dev/null | grep -c podenv_gate_probe || true)
     r=\$(podenv list 2>/dev/null | grep -c gate-probe || true)
     [ \"\$n\" = 0 ] && [ \"\$r\" = 0 ] && echo gone || echo \"containers=\$n rows=\$r\""

echo "── review findings (task-3-report.md) ──"

# F1a: an ordinary apostrophe in --dedicated must not break the underlying
# SQL. RED-proved manually pre-fix (see task-3-report.md): the raw INSERT
# died with `ERROR: syntax error at or near "s"`, exit 1 — outside the
# documented 0/2/3/4/5 contract, and the apostrophe is ordinary English, not
# an attack.
docker compose exec -T -u node paperclip sh -c "rm -f /tmp/f1-quote-gate.env" >/dev/null 2>&1
check "an apostrophe in --dedicated does not break provision (F1a)" \
    docker compose exec -T -u node paperclip sh -c \
    "podenv provision f1-quote-gate --image docker.io/traefik/whoami --port 80 --as F1_QUOTE_GATE --dedicated \"user's cache\" --env-file /tmp/f1-quote-gate.env"

check "the apostrophe renders correctly in podenv list (F1a)" \
    sh -c "docker compose exec -T -u node paperclip podenv list 2>&1 | grep -q \"dedicated: user's cache\""

check "the apostrophe renders correctly in devenv list (F1a)" \
    sh -c "docker compose exec -T -u node paperclip devenv list 2>&1 | grep -q \"dedicated: user's cache\""

check "F1a gate lease releases cleanly" \
    docker compose exec -T -u node paperclip podenv release f1-quote-gate

# F1b: a hostile --image is rejected before it ever reaches podman or the
# database. RED-proved manually pre-fix (see task-3-report.md): this exact
# value sailed past argument parsing (there was no charset gate at all),
# reached podman, and even left a stray row behind (the same failure F3b
# fixes) once podman rejected the reference.
expect "a hostile --image is rejected at exit 2, not accepted (F1b)" "2" \
    docker compose exec -T -u node paperclip sh -c \
    'podenv provision f1-image-gate --image "evil\$(true)image" --port 80 >/dev/null 2>&1; echo $?'

check "the rejected hostile image never created a row (F1b)" \
    sh -c '! docker compose exec -T -u node paperclip podenv list 2>&1 | grep -q f1-image-gate'

# F3a: a container that exists but fails to (re)start must be reported as a
# failure, not printed as success. Set up the exact scenario by hand: create
# (never start) a container whose entrypoint cannot exec, and register a
# matching row so `podenv provision` takes the "container already exists"
# branch. RED-proved manually pre-fix (see task-3-report.md): the identical
# setup printed "'f3-red' (existing) -> ...", exit 0, and wrote a .env
# pointing at a container that was never actually running.
docker compose exec -T -u node paperclip sh -c \
    'podman --remote --url unix:///run/podenv/podman.sock rm -f -v podenv_f3_gate >/dev/null 2>&1
     podman --remote --url unix:///run/podenv/podman.sock create --name podenv_f3_gate \
       --label opc.podenv.lease=podenv_f3_gate --label opc.podenv.key=f3-gate \
       --network=pasta -p 23010:80 docker.io/library/alpine:3.20 /nonexistent-binary' >/dev/null 2>&1
docker compose exec -T paperclip sh -c \
    'PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" psql -h "$DEVENV_PG_HOST" -U "$DEVENV_PG_ADMIN_USER" \
       -d "${DEVENV_CONTROL_DB:-devenv_control}" -v ON_ERROR_STOP=1 -c "
         DELETE FROM podenv_lease WHERE key = '"'"'f3-gate'"'"';
         INSERT INTO podenv_lease (key, slug, image, netns, container_port, host_port, env_var, created_by)
         VALUES ('"'"'f3-gate'"'"', '"'"'podenv_f3_gate'"'"', '"'"'docker.io/library/alpine:3.20'"'"', '"'"'pasta'"'"', 80, 23010, '"'"'F3_GATE_ADDR'"'"', '"'"'test'"'"')"' >/dev/null 2>&1

expect "a failed (re)start is reported as a failure, not success (F3a)" "5" \
    docker compose exec -T -u node paperclip sh -c \
    'podenv provision f3-gate --image docker.io/library/alpine:3.20 --port 80 --as F3_GATE_ADDR --env-file /tmp/f3-gate.env >/dev/null 2>&1; echo $?'

check "the failed start wrote no stale .env entry (F3a)" \
    sh -c '! docker compose exec -T -u node paperclip cat /tmp/f3-gate.env >/dev/null 2>&1'

# Cleanup: this key's row pre-dated the call (created_now=0), so the fix's
# rollback trap correctly leaves it in place (F3b: never tear down a
# pre-existing lease just because a later step had a bad day) — release it
# by hand instead, same as an operator would.
check "F3a gate lease and container clean up" \
    docker compose exec -T -u node paperclip sh -c \
    'podenv release f3-gate >/dev/null 2>&1
     podman --remote --url unix:///run/podenv/podman.sock rm -f -v podenv_f3_gate >/dev/null 2>&1
     rm -f /tmp/f3-gate.env
     true'

echo "── devenv coexistence ──"

# (b) variable-name partition. Refusing DATABASE_URL is what makes "postgres
# from devenv + Milvus from podenv" the only possible shape.
expect "refuses a variable name devenv owns" "refused" \
    docker compose exec -T -u node paperclip sh -c \
    'out=$(podenv provision name-clash --image docker.io/traefik/whoami --port 80 \
             --as DATABASE_URL 2>&1); rc=$?
     [ "$rc" = 2 ] && echo "$out" | grep -q "devenv" && echo refused || echo "rc=$rc out=$out"'
# F3: this must check the MESSAGE too, not just rc=2 — the implementer
# demonstrated it passing before the guard existed, because a dash
# redirection permission error in the container's default working directory
# (--env-file defaults to $PWD/.env, and $PWD here is not node-writable) also
# exits 2. rc=2 alone cannot distinguish "the guard fired" from "something
# else failed first"; grepping for "devenv" (as the sibling check above does)
# can.
expect "refuses the DEV_PORT_<n> family too" "refused" \
    docker compose exec -T -u node paperclip sh -c \
    'out=$(podenv provision name-clash --image docker.io/traefik/whoami --port 80 \
             --as DEV_PORT_2 2>&1); rc=$?
     [ "$rc" = 2 ] && echo "$out" | grep -q "devenv" && echo refused || echo "rc=$rc out=$out"'

# (c) route gate. redis is a family devenv serves, so an unqualified request
# must be refused and must name the devenv command.
expect "route gate refuses an image devenv already serves" "refused" \
    docker compose exec -T -u node paperclip sh -c \
    'out=$(podenv provision legacy-cache --image docker.io/library/redis:5 --port 6379 2>&1); rc=$?
     [ "$rc" = 2 ] && echo "$out" | grep -q "devenv provision" && echo refused || echo "rc=$rc out=$out"'
expect "--dedicated opens the gate and the reason is persisted" "pg9.6 client API" \
    docker compose exec -T -u node paperclip sh -c \
    'podenv provision legacy-pg --image docker.io/library/postgres:9.6 --port 5432 \
        --dedicated "pg9.6 client API" --password-env POSTGRES_PASSWORD \
        --env-file /tmp/podenv-dedicated.env >/dev/null 2>&1
     podenv list 2>/dev/null | grep -o "pg9.6 client API" | head -1'
expect "the dedicated reason shows up in devenv list too" "pg9.6 client API" \
    docker compose exec -T -u node paperclip sh -c \
    'devenv list 2>/dev/null | grep -o "pg9.6 client API" | head -1'
expect "--memory is refused rather than silently ignored" "refused" \
    docker compose exec -T -u node paperclip sh -c \
    'out=$(podenv provision mem-probe --image docker.io/traefik/whoami --port 80 --memory 128m 2>&1); rc=$?
     [ "$rc" = 2 ] && echo "$out" | grep -q "PODENV_MEM_LIMIT" && echo refused || echo "rc=$rc out=$out"'

# (F1) the family match must survive a registry/namespace prefix, a digest
# pin, a tag renaming, and case — measured evasions of the pre-fix
# `sed 's|.*/||; s|:.*||'`. All three refusals below must fire WITHOUT ever
# reaching podman (the gate sits before podenv_require_runtime), so no
# --env-file, container, or podenv_lease row is left behind to clean up.
expect "route gate catches a digest-pinned image (F1)" "refused" \
    docker compose exec -T -u node paperclip sh -c \
    'out=$(podenv provision f1-digest --port 5432 \
             --image docker.io/library/postgres@sha256:1111111111111111111111111111111111111111111111111111111111111111 2>&1); rc=$?
     [ "$rc" = 2 ] && echo "$out" | grep -q "devenv already serves" && echo refused || echo "rc=$rc out=$out"'
expect "route gate catches a renamed image of the SAME software, e.g. bitnami/postgresql (F1)" "refused" \
    docker compose exec -T -u node paperclip sh -c \
    'out=$(podenv provision f1-bitnami --image bitnami/postgresql:16 --port 5432 2>&1); rc=$?
     [ "$rc" = 2 ] && echo "$out" | grep -q "devenv already serves" && echo refused || echo "rc=$rc out=$out"'
expect "route gate catches an uppercase local tag (F1)" "refused" \
    docker compose exec -T -u node paperclip sh -c \
    'out=$(podenv provision f1-upper --image POSTGRES:16 --port 5432 2>&1); rc=$?
     [ "$rc" = 2 ] && echo "$out" | grep -q "devenv already serves" && echo refused || echo "rc=$rc out=$out"'

# (F1 regression guard) the alias set is a SMALL, closed list of renamings of
# what devenv actually serves — it must never grow to cover software devenv
# does not carry. mysql/milvus reach podman (a real attempt, not a stub) and
# are asserted NOT gated; whether podman itself can start them here is
# irrelevant to this gate, so this only fails "gated" if the route gate's
# refusal message shows up, not on any downstream podman error.
expect "route gate does NOT fire for MySQL — devenv does not serve it (F1)" "not-gated" \
    docker compose exec -T -u node paperclip sh -c \
    'out=$(podenv provision f1-neg-mysql --image mysql:5.7 --port 3306 --env-file /tmp/podenv-f1-neg-mysql.env 2>&1); rc=$?
     if [ "$rc" = 2 ] && echo "$out" | grep -q "devenv already serves"; then echo gated; else echo not-gated; fi'
expect "route gate does NOT fire for Milvus — devenv does not serve it (F1)" "not-gated" \
    docker compose exec -T -u node paperclip sh -c \
    'out=$(podenv provision f1-neg-milvus --image milvus/milvus:v2.5.0 --port 19530 --env-file /tmp/podenv-f1-neg-milvus.env 2>&1); rc=$?
     if [ "$rc" = 2 ] && echo "$out" | grep -q "devenv already serves"; then echo gated; else echo not-gated; fi'

# (F2) the lookup must be a string compare, not a sed/grep PATTERN match: a
# family containing a regex metacharacter (`.` here) must not false-positive
# against an unrelated family's line just because the pattern happens to
# match as a wildcard. Pre-fix this printed "devenv already serves
# 'p.stgres'" — a real image name (`.` is a valid OCI reference character),
# refused for software devenv has never heard of.
expect "the family lookup is a string compare, not a regex (F2)" "not-gated" \
    docker compose exec -T -u node paperclip sh -c \
    'out=$(podenv provision f2-metachar --image docker.io/library/p.stgres:1 --port 5432 --env-file /tmp/podenv-f2-metachar.env 2>&1); rc=$?
     if [ "$rc" = 2 ] && echo "$out" | grep -q "devenv already serves"; then echo gated; else echo not-gated; fi'

# cleanup so re-runs start clean
docker compose exec -T -u node paperclip sh -c \
    'podenv release legacy-pg >/dev/null 2>&1
     podenv release f1-neg-mysql >/dev/null 2>&1
     podenv release f1-neg-milvus >/dev/null 2>&1
     podenv release f2-metachar >/dev/null 2>&1
     rm -f /tmp/podenv-dedicated.env /tmp/podenv-f1-neg-mysql.env \
           /tmp/podenv-f1-neg-milvus.env /tmp/podenv-f2-metachar.env' >/dev/null 2>&1

echo "── restore ──"

#
# CORRECTED NOTE (previous claim measured false — see task-5-report.md): an
# earlier version of this gate asserted that `docker compose restart podenv`
# "did not reproduce a RED condition" because `podman ps -a` showed
# uninterrupted uptime spanning the restart. That was reading podman's
# RECORDED state, not reality — the exact class of bug this whole check
# exists to catch. Measured on this host: `restart` DOES kill the lease's
# real processes (the outer container's PID namespace is torn down), but
# because `restart` preserves the podenv container's writable layer,
# `/run/user/1000` (podman's rootless runtime state, created there by the
# entrypoint — not a tmpfs mount, confirmed via `/proc/mounts`) survives, and
# podman goes on reporting the lease "Up" with a live-looking uptime while its
# recorded pid no longer exists in `/proc` and nothing answers on its port.
# `--force-recreate` builds a fresh writable layer, so that stale state is
# absent, podman correctly reports "exited", and a plain `podman start`
# genuinely revives it — which is why the OLD version of this check, driven
# only through `--force-recreate`, stayed green while `restart` silently
# rotted leases in production. So this gate now drives BOTH paths, and
# neither trusts `podman ps`/`inspect` state: only an HTTP request through
# the lease's own published port counts as "genuinely serving".
podenv_restore_probe() {
    label="$1"; disrupt="$2"
    docker compose exec -T -u node paperclip sh -c \
        'podenv provision restore-probe --image docker.io/traefik/whoami --port 80 \
            --as RESTORE_ADDR --env-file /tmp/podenv-restore.env >/dev/null 2>&1'
    addr="$(docker compose exec -T -u node paperclip sh -c \
        'grep "^RESTORE_ADDR=" /tmp/podenv-restore.env | cut -d= -f2-' 2>/dev/null | tr -d '\r')"
    if [ -z "$addr" ]; then
        fail "$label (provision produced no RESTORE_ADDR — nothing to probe)"
        return
    fi
    eval "$disrupt"
    code=""
    for i in $(seq 1 45); do
        code="$(docker compose exec -T -u node paperclip sh -c \
            "curl -s -o /dev/null -w '%{http_code}' --max-time 3 'http://$addr/'" 2>/dev/null | tr -d '\r')"
        [ "$code" = "200" ] && break
        sleep 2
    done
    if [ "$code" = "200" ]; then
        pass "$label"
    else
        fail "$label (want HTTP 200 through $addr, got '$code')"
    fi
}

podenv_restore_probe "a lease genuinely serves traffic after 'docker compose restart podenv'" \
    'docker compose restart podenv >/dev/null 2>&1'

podenv_restore_probe "a lease genuinely serves traffic after '--force-recreate podenv'" \
    'docker compose up -d --force-recreate podenv >/dev/null 2>&1'

docker compose exec -T -u node paperclip sh -c \
    'podenv release restore-probe >/dev/null 2>&1; rm -f /tmp/podenv-restore.env' >/dev/null 2>&1

echo "── provision re-run after restart (not restore's fix) ──"

# task-5: cmd_provision's OWN idempotent "container exists" branch had the
# identical false-authoritative-state bug the "restore" section above
# guards — a bare `podman start` on a stale-"running" container measured to
# return success without reviving anything (see opc-podenv-restore.sh's
# header and patches/paperclip/podenv/podenv's comment above the "container
# exists" branch). This is worse than the restore path: `provision` is the
# DOCUMENTED, routine way an agent picks a lease back up, so a silent false
# success here hands back a dead address on the happy path.
#
# opc-podenv-restore.sh ALSO revives every podenv-labelled container on the
# podenv service's own boot (backgrounded from its entrypoint, gated on the
# socket appearing). A check driven through `docker compose restart podenv`
# therefore risks measuring restore's fix instead of provision's own —
# exactly the ambiguity this section has to rule out, not just tolerate.
# Distinguished by racing on wall-clock time, not by lease shape: podman's
# own socket takes a beat to come back up after the restart, and restore's
# boot-time pass cannot even start until it does (its own poll loop checks
# every 2s); `podenv provision` from paperclip has to clear the exact same
# socket-readiness gate, so calling it IMMEDIATELY after `docker compose
# restart podenv` returns races provision's own path against restore's
# rather than against a pre-revived container. Measured (task-5-report.md):
# multiple trials against the pre-fix CLI this way all reproduced the bug —
# provision exited 0 while the address was still dead — with the restore
# script's own log line for this exact lease landing 2-4 SECONDS AFTER the
# provision call had already returned, confirming the race was won every
# time it was tried. This is an empirical guarantee, not a structural one:
# nothing here forces the ordering, it is only reliably fast enough that
# restore has not gotten there yet. If this ever starts flaking, that is
# itself a real signal, not a test bug to silence.
docker compose exec -T -u node paperclip sh -c 'rm -f /tmp/podenv-race.env'
docker compose exec -T -u node paperclip sh -c \
    'podenv provision race-probe --image docker.io/traefik/whoami --port 80 \
        --as RACE_ADDR --env-file /tmp/podenv-race.env' >/dev/null

docker compose restart podenv >/dev/null 2>&1

_race_out="$(docker compose exec -T -u node paperclip sh -c \
    'podenv provision race-probe --image docker.io/traefik/whoami --port 80 \
        --as RACE_ADDR --env-file /tmp/podenv-race.env >/tmp/podenv-race.out 2>&1
     echo "RC=$?"' 2>/dev/null | tr -d '\r')"
_race_rc="$(printf '%s\n' "$_race_out" | sed -n 's/^RC=//p' | tail -1)"
_race_addr="$(docker compose exec -T -u node paperclip sh -c \
    'grep "^RACE_ADDR=" /tmp/podenv-race.env 2>/dev/null | cut -d= -f2-' 2>/dev/null | tr -d '\r')"

if [ "$_race_rc" = "0" ]; then
    if [ -z "$_race_addr" ]; then
        fail "provision re-run after restart: exit 0 but wrote no RACE_ADDR (nothing to probe)"
    else
        _race_code="$(docker compose exec -T -u node paperclip sh -c \
            "curl -s -o /dev/null -w '%{http_code}' --max-time 3 'http://$_race_addr/'" 2>/dev/null | tr -d '\r')"
        if [ "$_race_code" = "200" ]; then
            pass "provision re-run after restart: exit 0 AND the address genuinely answers (HTTP 200)"
        else
            fail "provision re-run after restart reported SUCCESS (exit 0) for a DEAD lease (http '$_race_code' through $_race_addr) — the exact bug this gate exists to catch"
        fi
    fi
elif [ "$_race_rc" = "5" ]; then
    pass "provision re-run after restart failed loudly (exit 5, the documented code) instead of claiming success"
else
    _race_msg="$(docker compose exec -T -u node paperclip cat /tmp/podenv-race.out 2>/dev/null)"
    fail "provision re-run after restart returned an undocumented exit ('$_race_rc') — output: $_race_msg"
fi

docker compose exec -T -u node paperclip sh -c \
    'podenv release race-probe >/dev/null 2>&1
     rm -f /tmp/podenv-race.env /tmp/podenv-race.out' >/dev/null 2>&1

echo "── task-6: create-path liveness (F1) ──"

# F1: cmd_provision's fresh-create path (`run -d` on a brand new lease) had
# NO liveness check at all — `run -d` returning 0 only proves podman
# ACCEPTED the request, not that the container stayed up. Plain alpine with
# no CMD exits almost instantly. RED-proved manually pre-fix (this task,
# see task-5-report.md): this exact call returned exit 0 and wrote
# NOLISTEN_ADDR=podenv:23000 into the env file while `podman ps -a` showed
# `Exited (0) Less than a second ago` — a lease handed out for a container
# that never ran, and the row was left registered (`podenv list` showed it).
docker compose exec -T -u node paperclip sh -c \
    'rm -f /tmp/podenv-f1-create.env /tmp/podenv-f1-create.out'

expect "a die-immediately image fails provision loudly, not exit 0 (F1 create path)" "5" \
    docker compose exec -T -u node paperclip sh -c \
    'podenv provision f1-create-gate --image docker.io/library/alpine:3.20 --port 80 \
        --as F1_CREATE_GATE --env-file /tmp/podenv-f1-create.env >/tmp/podenv-f1-create.out 2>&1; echo $?'

check "the failure message points at 'podman logs' (F1 create path)" \
    sh -c "docker compose exec -T -u node paperclip cat /tmp/podenv-f1-create.out 2>&1 | grep -q 'podman logs'"

check "the failed create wrote no stale .env entry (F1 create path)" \
    sh -c '! docker compose exec -T -u node paperclip cat /tmp/podenv-f1-create.env >/dev/null 2>&1'

# The whole point of arming the EXIT trap before container creation: a
# provision THIS invocation failed must not leave a registry row behind —
# `podenv list` showing a lease for a container that never ran is exactly
# the defect class the last two review rounds were about.
check "the die-immediately lease left no registry row behind (F1 create path)" \
    sh -c '! docker compose exec -T -u node paperclip podenv list 2>&1 | grep -q f1-create-gate'

check "the die-immediately lease left no container behind (F1 create path)" \
    sh -c '! docker compose exec -T -u node paperclip sh -c \
        "podman --remote --url unix:///run/podenv/podman.sock ps -a --format \"{{.Names}}\"" 2>&1 \
        | grep -q podenv_f1_create_gate'

docker compose exec -T -u node paperclip sh -c \
    'rm -f /tmp/podenv-f1-create.env /tmp/podenv-f1-create.out' >/dev/null 2>&1

echo "── task-6: liveness probe honesty (F2) ──"

# F2: the previous fix round measured that pasta's port-forwarder completes
# the TCP handshake with the caller EVEN WHEN NOTHING IS LISTENING on the
# forwarded port inside the container — so a bare connect proves only "the
# forwarder is up," never "the daemon answers." Reproduce the exact ambiguous
# window here: a container that is genuinely RUNNING (so F1's check above
# would not catch it) but has nothing bound to its leased port at all
# (alpine sleeping, no CMD that binds anything).
docker compose exec -T -u node paperclip sh -c \
    'podman --remote --url unix:///run/podenv/podman.sock rm -f -v podenv_f2_probe >/dev/null 2>&1
     podman --remote --url unix:///run/podenv/podman.sock run -d --name podenv_f2_probe \
       --label opc.podenv.lease=podenv_f2_probe --label opc.podenv.key=f2-probe \
       --network=pasta -p 23011:80 docker.io/library/alpine:3.20 sleep 300 >/dev/null 2>&1'

check "the F2 measurement lease is genuinely RUNNING (setup sanity)" \
    sh -c 'docker compose exec -T -u node paperclip sh -c \
        "podman --remote --url unix:///run/podenv/podman.sock inspect podenv_f2_probe --format \"{{.State.Running}}\"" \
        2>/dev/null | tr -d "\r" | grep -qx true'

# The measured lie itself, reproduced directly: a bare TCP connect succeeds
# against this lease even though nothing behind it is listening.
check "a bare TCP connect succeeds anyway (measured pasta forwarder behaviour, F2)" \
    docker compose exec -T podenv timeout 2 sh -c ': < /dev/tcp/127.0.0.1/23011'

# opc-podenv-restore.sh's own probe, run directly (idempotent, socket is
# already up so it does not block): it must not claim this lease as
# "restored" using language the probe cannot back up.
_f2_restore_line="$(docker compose exec -T podenv /usr/local/bin/opc-podenv-restore.sh 2>&1 | grep podenv_f2_probe | tail -1)"
if printf '%s\n' "$_f2_restore_line" | grep -q '^\[podenv-restore\] restored podenv_f2_probe'; then
    fail "opc-podenv-restore.sh must not report this lease as restored — nothing answers (F2) (got: $_f2_restore_line)"
else
    pass "opc-podenv-restore.sh does not claim success for a lease that never exchanges data (F2)"
fi
if printf '%s\n' "$_f2_restore_line" | grep -qi 'answer'; then
    fail "opc-podenv-restore.sh's wording still claims the port 'answers' — the exact overclaim F2 is about (got: $_f2_restore_line)"
else
    pass "opc-podenv-restore.sh's wording no longer claims the port 'answers' (F2)"
fi

# cmd_provision's reprovision branch ("container exists") on the exact same
# lease shape: register a matching row (mirrors the F3-gate setup above) so
# `podenv provision` takes that branch, and require the SAME honesty — it
# must fail loudly rather than report exit 0 for a lease nothing answers on.
docker compose exec -T paperclip sh -c \
    'PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" psql -h "$DEVENV_PG_HOST" -U "$DEVENV_PG_ADMIN_USER" \
       -d "${DEVENV_CONTROL_DB:-devenv_control}" -v ON_ERROR_STOP=1 -c "
         DELETE FROM podenv_lease WHERE key = '"'"'f2-probe'"'"';
         INSERT INTO podenv_lease (key, slug, image, netns, container_port, host_port, env_var, created_by)
         VALUES ('"'"'f2-probe'"'"', '"'"'podenv_f2_probe'"'"', '"'"'docker.io/library/alpine:3.20'"'"', '"'"'pasta'"'"', 80, 23011, '"'"'F2_PROBE_ADDR'"'"', '"'"'test'"'"')"' >/dev/null 2>&1

docker compose exec -T -u node paperclip sh -c 'rm -f /tmp/podenv-f2.env /tmp/podenv-f2.out'

expect "reprovision on a running-but-unbound lease fails loudly, not exit 0 (F2)" "5" \
    docker compose exec -T -u node paperclip sh -c \
    'podenv provision f2-probe --image docker.io/library/alpine:3.20 --port 80 \
        --as F2_PROBE_ADDR --env-file /tmp/podenv-f2.env >/tmp/podenv-f2.out 2>&1; echo $?'

check "the failed reprovision wrote no stale .env entry (F2)" \
    sh -c '! docker compose exec -T -u node paperclip cat /tmp/podenv-f2.env >/dev/null 2>&1'

check "the reprovision failure message does not claim the port 'answers' (F2)" \
    sh -c "! docker compose exec -T -u node paperclip cat /tmp/podenv-f2.out 2>&1 | grep -qi 'never answered'"

# Cleanup. This key's row pre-dated the call (created_now=0 — it was
# inserted by hand above, the same as the F3-gate section), so the rollback
# trap correctly leaves it in place; release it by hand like an operator
# would, same convention as the F3-gate cleanup above.
docker compose exec -T -u node paperclip sh -c \
    'podenv release f2-probe >/dev/null 2>&1
     podman --remote --url unix:///run/podenv/podman.sock rm -f -v podenv_f2_probe >/dev/null 2>&1
     rm -f /tmp/podenv-f2.env /tmp/podenv-f2.out' >/dev/null 2>&1

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
