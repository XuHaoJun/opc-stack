#!/bin/sh
# Integration test for patches/buzz/opc-register-agent.sh using fake
# curl/buzz/jq/sleep executables prepended to PATH. Every buzz invocation the
# production script makes is recorded verbatim in a call log; nothing touches a
# real relay or the live stack. The fake sleep exits 99 after the second call
# so the production infinite reconciler runs exactly two loop iterations and
# then terminates, which lets the retry case prove that kind 0 is not
# republished while kind 10100 is.
#
# Asserted behaviour (brief Step 1 + Step 4):
#   * initial boot publishes BOTH surfaces — `users set-profile` (kind 0) and
#     `channels set-add-policy --policy anyone` (kind 10100) — once each;
#   * retry: kind 10100 fails once while kind 0 succeeds; on the next loop
#     kind 0 is NOT republished and kind 10100 IS retried;
#   * every buzz call carries the relay + private-key prefix (the CLI injects
#     the ambient BUZZ_AUTH_TAG itself — the script never builds tags).
set -eu
cd "$(dirname "$0")/.."

PROD="patches/buzz/opc-register-agent.sh"
[ -f "$PROD" ] || { echo "FAIL  production script missing: $PROD"; exit 1; }

PROFILE_CMD="users set-profile --name hermes --about OPC front-door agent (hermes + opencode go)"
POLICY_CMD="channels set-add-policy --policy anyone"
RELAY_PREFIX="--relay http://relay.test --private-key"

PASS=0; FAIL=0
pass() { echo "PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }

cnt() { # cnt <call-log> <needle> — number of lines containing needle
    grep -cF -- "$2" "$1" || true
}

make_fake_bin() { # make_fake_bin <dir> <case> — fake curl/buzz/jq/sleep
    dir="$1"; case="$2"
    cat > "$dir/curl" <<'FAKE_EOF'
#!/bin/sh
# Deterministic fake `curl`: the relay readiness probe always succeeds.
printf 'curl %s\n' "$*" >> "${FAKE_CALL_LOG:?}"
exit 0
FAKE_EOF
    cat > "$dir/jq" <<'FAKE_EOF'
#!/bin/sh
# Deterministic fake `jq`: reads the buzz JSON on stdin and returns the
# channel ids of the FIRST `channels list` call (all channels). The second
# call is `channels list --member` — the --member flag goes to buzz, not jq,
# so the fake distinguishes the calls by checking whether a `channels list`
# is already recorded in the call log. Matches the real invocation shape
# `jq -r '.[].channel_id'`.
printf 'jq %s\n' "$*" >> "${FAKE_CALL_LOG:?}"
if ! grep -qF -- "channels list" "$FAKE_CALL_LOG" 2>/dev/null \
    || [ "$(grep -cF -- "channels list" "$FAKE_CALL_LOG")" = 1 ]; then
    sed -n 's/.*"channel_id":"\([^"]*\)".*/\1/p' "${FAKE_CHANNELS_JSON:-}"
fi
exit 0
FAKE_EOF
    cat > "$dir/sleep" <<'FAKE_EOF'
#!/bin/sh
# Fake `sleep`: records the call, exits 0 after the first loop iteration so
# the reconciler runs a second one, then exits 99 so the infinite loop
# terminates under test (run once: fake 99 → production script exits 99).
printf 'sleep %s\n' "$*" >> "${FAKE_CALL_LOG:?}"
if [ -f "${FAKE_SLEEP_COUNT:-}" ]; then
    n="$(cat "$FAKE_SLEEP_COUNT")"
    echo "$((n + 1))" > "$FAKE_SLEEP_COUNT"
    [ "$n" -ge 1 ] && exit 99
fi
exit 0
FAKE_EOF
    cat > "$dir/buzz" <<'FAKE_EOF'
#!/bin/sh
# Deterministic fake `buzz`: records every argv vector verbatim, then mimics
# the CLI for the surface the register script exercises.
printf 'buzz %s\n' "$*" >> "${FAKE_CALL_LOG:?}"
case "$*" in
    *"channels list"*)
        cat "${FAKE_CHANNELS_JSON:-}"
        exit 0 ;;
    *"channels set-add-policy"*)
        # retry case: first attempt fails, subsequent attempts succeed
        if [ "${FAKE_CASE:-happy}" = "retry" ] && [ ! -f "${FAKE_POLICY_OK:-}" ]; then
            : > "$FAKE_POLICY_OK"
            exit 1
        fi
        exit 0 ;;
    *"channels add-member"*|*"users set-profile"*)
        exit 0 ;;
    *)
        printf 'fake: unexpected buzz invocation: %s\n' "$*" >&2
        exit 1 ;;
esac
FAKE_EOF
    chmod +x "$dir/curl" "$dir/jq" "$dir/sleep" "$dir/buzz"
}

make_keys() { # make_keys <dir> — fixture agent/relay key files
    printf '%s\n' "a6a7f8703a3edc6024af943142f51583904a8df74a205566cf9d57e02e447004" > "$dir/agent.pub"
    printf '%s\n' "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" > "$dir/agent.nsec"
    printf '%s\n' "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" > "$dir/relay.nsec"
}

# ── initial dual publication (both surfaces once, then sleep → exit 99) ──────
dir="$(mktemp -d)"
make_keys "$dir"
make_fake_bin "$dir" happy
printf '%s\n' '[{"channel_id":"cid-1"}]' > "$dir/channels.json"
: > "$dir/calls"
: > "$dir/sleep-count"
env PATH="$dir:$PATH" BUZZ_KEYS_DIR="$dir" BUZZ_RELAY_URL="ws://relay.test" \
    FAKE_CALL_LOG="$dir/calls" FAKE_SLEEP_COUNT="$dir/sleep-count" \
    FAKE_CHANNELS_JSON="$dir/channels.json" FAKE_CASE=happy sh "$PROD" \
    >"$dir/out" 2>&1 || rc=$?
if [ "${rc:-}" = 99 ]; then pass "happy: reconciler terminated after 2 loops (sleep exit 99)"; else fail "happy: expected exit 99, got ${rc:-}"; fi
if grep -qF "$PROFILE_CMD" "$dir/calls"; then pass "happy: kind 0 published: $PROFILE_CMD"; else fail "happy: kind 0 NOT published: $PROFILE_CMD"; fi
if grep -qF "$POLICY_CMD" "$dir/calls"; then pass "happy: kind 10100 published: $POLICY_CMD"; else fail "happy: kind 10100 NOT published: $POLICY_CMD"; fi
if [ "$(cnt "$dir/calls" "$PROFILE_CMD")" = 1 ]; then pass "happy: kind 0 published exactly once"; else fail "happy: kind 0 published $(cnt "$dir/calls" "$PROFILE_CMD") times (want 1)"; fi
if [ "$(cnt "$dir/calls" "$POLICY_CMD")" = 1 ]; then pass "happy: kind 10100 published exactly once"; else fail "happy: kind 10100 published $(cnt "$dir/calls" "$POLICY_CMD") times (want 1)"; fi
if grep -qF -- "channels add-member --channel cid-1" "$dir/calls"; then pass "happy: joined visible channel cid-1"; else fail "happy: did not join visible channel cid-1"; fi
n_relay="$(cnt "$dir/calls" "$RELAY_PREFIX")"
n_buzz="$(cnt "$dir/calls" "buzz ")"
if [ "$n_relay" = "$n_buzz" ]; then pass "happy: every buzz call carries relay+key prefix ($n_relay)"; else fail "happy: $n_relay of $n_buzz buzz calls carry relay+key prefix"; fi
rm -rf "$dir"

# ── retry: kind 10100 fails once, kind 0 succeeds; next loop only 10100 ──────
dir="$(mktemp -d)"
make_keys "$dir"
make_fake_bin "$dir" retry
printf '%s\n' '[{"channel_id":"cid-1"}]' > "$dir/channels.json"
: > "$dir/calls"
: > "$dir/sleep-count"
env PATH="$dir:$PATH" BUZZ_KEYS_DIR="$dir" BUZZ_RELAY_URL="ws://relay.test" \
    FAKE_CALL_LOG="$dir/calls" FAKE_SLEEP_COUNT="$dir/sleep-count" \
    FAKE_CHANNELS_JSON="$dir/channels.json" FAKE_CASE=retry \
    FAKE_POLICY_OK="$dir/policy-ok" sh "$PROD" >"$dir/out" 2>&1 || rc=$?
if [ "${rc:-}" = 99 ]; then pass "retry: reconciler terminated after 2 loops (sleep exit 99)"; else fail "retry: expected exit 99, got ${rc:-}"; fi
if [ "$(cnt "$dir/calls" "$PROFILE_CMD")" = 1 ]; then pass "retry: kind 0 published once (not republished on retry loop)"; else fail "retry: kind 0 published $(cnt "$dir/calls" "$PROFILE_CMD") times (want 1)"; fi
if [ "$(cnt "$dir/calls" "$POLICY_CMD")" = 2 ]; then pass "retry: kind 10100 retried (2 attempts: 1 fail + 1 success)"; else fail "retry: kind 10100 attempts = $(cnt "$dir/calls" "$POLICY_CMD") (want 2)"; fi
if [ -f "$dir/policy-ok" ]; then pass "retry: kind 10100 eventually succeeded"; else fail "retry: kind 10100 never succeeded"; fi
if grep -q "kind 10100 agent directory profile published" "$dir/out"; then pass "retry: success logged after retry"; else fail "retry: missing success log: $(grep 'kind 10100' "$dir/out" || true)"; fi
rm -rf "$dir"

echo
echo "result: ${PASS} pass, ${FAIL} fail"
[ "$FAIL" = 0 ]
