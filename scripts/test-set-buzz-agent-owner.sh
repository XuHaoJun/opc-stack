#!/bin/sh
# Integration test for scripts/set-buzz-agent-owner.sh using a fake `docker`
# executable prepended to PATH. The fake returns deterministic fixtures, so
# the test never touches a real daemon or the live stack; every docker
# invocation the production script makes is intercepted and recorded in a call
# log. Each failure case must leave the fixture .env byte-identical to its
# pre-run checksum, and the owner pkey content must never appear in the
# production script's output.
set -eu
cd "$(dirname "$0")/.."

PROD="$PWD/scripts/set-buzz-agent-owner.sh"
SELECTOR="noah"

OWNER_PUBKEY="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
OTHER_OWNER="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
AGENT_PUBKEY="a6a7f8703a3edc6024af943142f51583904a8df74a205566cf9d57e02e447004"
SIG="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
AUTH_TAG="[\"auth\",\"$OWNER_PUBKEY\",\"\",\"$SIG\"]"
OLD_TAG="[\"auth\",\"$OWNER_PUBKEY\",\"\",\"00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000\"]"
KEY_SECRET="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

PASS=0; FAIL=0
pass() { echo "PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }

assert_line() { # assert_line <case-label> <file> <expected-line>
    if grep -qxF "$3" "$2" >/dev/null 2>&1; then
        pass "$1: line present: $3"
    else
        fail "$1: missing line: $3"
    fi
}
assert_count() { # assert_count <case-label> <file> <egrep-pattern> <expected>
    n="$(grep -cE "$3" "$2" || true)"
    if [ "$n" = "$4" ]; then
        pass "$1: count $4 for $3"
    else
        fail "$1: count $n (want $4) for $3"
    fi
}
assert_called() { # assert_called <case-label> <call-log> <needle>
    if grep -qF "$3" "$2" >/dev/null 2>&1; then
        pass "$1: invoked: $3"
    else
        fail "$1: NOT invoked: $3"
    fi
}
assert_not_called() { # assert_not_called <case-label> <call-log> <needle>
    if grep -qF "$3" "$2" >/dev/null 2>&1; then
        fail "$1: should NOT have invoked: $3"
    else
        pass "$1: not invoked (as expected): $3"
    fi
}

make_fake_docker() { # make_fake_docker <dir>
    cat > "$1/docker" <<'FAKE_EOF'
#!/bin/sh
# Deterministic fake `docker` for scripts/set-buzz-agent-owner.sh tests.
# Behaviour is selected by $FAKE_DOCKER_CASE; every invocation is appended to
# $FAKE_CALL_LOG. Fixture values come from $FAKE_OWNER / $FAKE_AGENT /
# $FAKE_TAG / $FAKE_OTHER. Unknown invocation shapes exit 1 so the test fails
# if the production script ever calls a docker command the fake does not know.
set -eu
printf 'docker %s\n' "$*" >> "${FAKE_CALL_LOG:?}"

case "$*" in
    *"compose config --format json"*)
        printf '%s\n' '{"services":{"frontdoor":{"image":"opc/frontdoor:local"}}}'
        exit 0 ;;
esac

case "$*" in
    *"compose exec -T buzz-db psql"*)
        sql="${sql:-}"
        prev=""
        for a in "$@"; do
            [ "$prev" = "-c" ] && sql="$a"
            prev="$a"
        done
        case "$sql" in
            *"agent_owner_pubkey IS NULL"*)
                case "${FAKE_DOCKER_CASE:-happy}" in
                    zero) : ;;
                    two) printf '%s\tNoah\thuman\n%s\tEve\thuman\n' "$FAKE_OWNER" "$FAKE_OTHER" ;;
                    agent) printf '%s\tNoah\tagent\n' "$FAKE_OWNER" ;;
                    *) printf '%s\tNoah\thuman\n' "$FAKE_OWNER" ;;
                esac ;;
            *"kind = 10100"*) printf '[%s]\n' "$FAKE_TAG" ;;
            *"kind = 0"*)     printf '[%s]\n' "$FAKE_TAG" ;;
            *"agent_owner_pubkey"*) printf '%s\n' "$FAKE_OWNER" ;;
            *) printf 'fake: unexpected psql query: %s\n' "$sql" >&2; exit 1 ;;
        esac
        exit 0 ;;
    *"compose run --rm --no-deps"*)
        printf '%s\n' "$FAKE_AGENT"; exit 0 ;;
    *"image inspect"*)
        exit 0 ;;
    *"--network none"*)
        cat >/dev/null          # consume the owner secret; never echo it
        if [ "${FAKE_DOCKER_CASE:-happy}" = "signer" ]; then
            printf '%s\n' "owner key does not match resolved Buzz identity" >&2
            exit 3
        fi
        printf '%s\n' "$FAKE_TAG"; exit 0 ;;
    *"compose up"*)
        exit 0 ;;
    *"compose logs"*)
        printf '%s\n' "2026-08-19T00:00:00Z  INFO buzz_acp: owner resolved from BUZZ_AUTH_TAG: $FAKE_OWNER"
        exit 0 ;;
    *)
        printf 'fake: unexpected docker invocation: %s\n' "$*" >&2; exit 1 ;;
esac
FAKE_EOF
    chmod +x "$1/docker"
}

make_fixture() { # make_fixture <dir> <case> — .env fixture + 0600 key file
    dir="$1"; case="$2"
    key_file="$dir/owner-pkey.txt"
    printf '%s\n' "$KEY_SECRET" > "$key_file"
    chmod 600 "$key_file"
    case "$case" in keymode) chmod 644 "$key_file" ;; esac
    {
        echo "# OPC stack fixture (fake-docker test)"
        echo "IMAGE_PREFIX=opc"
        echo "BUZZ_RELAY_URL=ws://localhost:3000"
        if [ "$case" = preowned ]; then
            echo "BUZZ_ACP_AGENT_OWNER=$OTHER_OWNER"
            echo "BUZZ_AUTH_TAG=[\"auth\",\"$OTHER_OWNER\",\"\",\"$SIG\"]"
        else
            echo "BUZZ_ACP_AGENT_OWNER=$OWNER_PUBKEY"
            echo "BUZZ_AUTH_TAG=$OLD_TAG"
        fi
        case "$case" in nokey) : ;; *) echo "BUZZ_OWNER_KEY_FILE=$key_file" ;; esac
        echo "DEVENV_HTTP_BIND=100.92.16.32"
        echo "# trailing comment — must survive the atomic rewrite"
    } > "$dir/.env"
    make_fake_docker "$dir"
}

run_prod() { # run_prod <dir> <case> — runs production script; sets $out $rc
    set +e
    out="$(PATH="$1:$PATH" OPC_ENV_FILE="$1/.env" FAKE_DOCKER_CASE="$2" \
        FAKE_CALL_LOG="$1/calls" FAKE_OWNER="$OWNER_PUBKEY" \
        FAKE_AGENT="$AGENT_PUBKEY" FAKE_TAG="$AUTH_TAG" FAKE_OTHER="$OTHER_OWNER" \
        "$PROD" "$SELECTOR" < /dev/null 2>&1)"
    rc=$?
    set -e
}

no_leak() { # no_leak <case-label> <out>
    case "$2" in
        *"$KEY_SECRET"*) fail "$1: owner key secret leaked into output" ;;
        *) pass "$1: no owner key secret in output" ;;
    esac
}

# ── happy path: name lookup → sign → atomic rewrite → recreate → verify ──────
dir="$(mktemp -d)"
make_fixture "$dir" happy
mode_before="$(stat -c %a "$dir/.env")"
run_prod "$dir" happy
if [ "$rc" -eq 0 ]; then pass "happy: exit 0"; else fail "happy: exit $rc: $out"; fi
assert_line "happy" "$dir/.env" "BUZZ_ACP_AGENT_OWNER=$OWNER_PUBKEY"
assert_line "happy" "$dir/.env" "BUZZ_AUTH_TAG=$AUTH_TAG"
assert_line "happy" "$dir/.env" "BUZZ_OWNER_KEY_FILE=$dir/owner-pkey.txt"
assert_count "happy" "$dir/.env" '^BUZZ_AUTH_TAG=' 1
assert_count "happy" "$dir/.env" '^BUZZ_ACP_AGENT_OWNER=' 1
assert_count "happy" "$dir/.env" '^BUZZ_OWNER_KEY_FILE=' 1
assert_called "happy" "$dir/calls" 'compose up -d --no-deps --force-recreate frontdoor'
if grep -qF "DEVENV_HTTP_BIND=100.92.16.32" "$dir/.env" \
   && grep -qF "# trailing comment" "$dir/.env"; then
    pass "happy: unrelated lines and comments preserved"
else
    fail "happy: unrelated lines/comments lost"
fi
if [ "$(stat -c %a "$dir/.env")" = "$mode_before" ]; then
    pass "happy: .env mode preserved ($mode_before)"
else
    fail "happy: .env mode changed ($mode_before → $(stat -c %a "$dir/.env"))"
fi
no_leak "happy" "$out"
rm -rf "$dir"

# ── failure cases: loud error, instruction, and byte-identical fixture ───────
expect_fail() { # expect_fail <label> <dir> <sum-before> <msg-needle>
    label="$1"; dir="$2"; sum="$3"; needle="$4"
    if [ "$rc" -ne 0 ]; then
        pass "$label: failed as expected (exit $rc)"
    else
        fail "$label: expected failure but exit 0: $out"
    fi
    case "$out" in
        *"$needle"*) pass "$label: error names boundary: $needle" ;;
        *) fail "$label: error lacks '$needle': $(printf '%s' "$out" | head -n 3)" ;;
    esac
    if [ "$(sha256sum "$dir/.env" | cut -d' ' -f1)" = "$sum" ]; then
        pass "$label: fixture .env byte-identical"
    else
        fail "$label: fixture .env was modified on failure"
    fi
}
fail_case() { # fail_case <label> <case> <msg-needle>
    label="$1"; c="$2"; needle="$3"
    dir="$(mktemp -d)"
    make_fixture "$dir" "$c"
    sum="$(sha256sum "$dir/.env" | cut -d' ' -f1)"
    run_prod "$dir" "$c"
    expect_fail "$label" "$dir" "$sum" "$needle"
    no_leak "$label" "$out"
    rm -rf "$dir"
}

fail_case "zero-matches"  zero     "no active Buzz account matches"
fail_case "two-matches"   two      "ambiguous selector"
fail_case "agent-owner"   agent    "not a human"
fail_case "key-mode-0644" keymode  "must not grant group/other access"
fail_case "signer-mismatch" signer "signing failed"
fail_case "pre-existing-owner" preowned "already owned by"

# rotation check must fail BEFORE reading the agent pubkey or signing
dir="$(mktemp -d)"
make_fixture "$dir" preowned
sum="$(sha256sum "$dir/.env" | cut -d' ' -f1)"
run_prod "$dir" preowned
expect_fail "pre-owned-fast-fail" "$dir" "$sum" "already owned by"
assert_not_called "pre-owned-fast-fail" "$dir/calls" "compose run --rm --no-deps"
assert_not_called "pre-owned-fast-fail" "$dir/calls" "--network none"
rm -rf "$dir"

# non-TTY missing BUZZ_OWNER_KEY_FILE must fail with an instruction, not hang
dir="$(mktemp -d)"
make_fixture "$dir" nokey
sum="$(sha256sum "$dir/.env" | cut -d' ' -f1)"
run_prod "$dir" nokey
expect_fail "missing-key-file" "$dir" "$sum" "BUZZ_OWNER_KEY_FILE is not set"
no_leak "missing-key-file" "$out"
rm -rf "$dir"

echo
echo "result: ${PASS} pass, ${FAIL} fail"
[ "$FAIL" = 0 ]
