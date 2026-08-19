#!/bin/sh
# Smoke test for the network-isolated NIP-OA owner attestation signer
# (patches/buzz/opc-nip-oa-sign.rs).
#
# Builds the opc-frontdoor image, feeds the helper a deterministic owner
# secret through stdin (--network none so the secret never reaches a socket),
# and asserts:
#   - the JSON tag has shape ["auth", <owner>, "", <128-hex-sig>]
#   - the owner mismatch path exits 3
#   - neither stdout nor stderr ever contains the owner secret
#
# Cryptographic verification of the produced signature is a Rust unit test
# beside `run` (cargo test inside the image build).
set -eu
cd "$(dirname "$0")/.."

IMAGE="${IMAGE_PREFIX:-opc}/frontdoor:owner-signer-test"
OWNER_SECRET="0000000000000000000000000000000000000000000000000000000000000001"
OWNER_PUBKEY="79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
AGENT_PUBKEY="c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
MISMATCH_PUBKEY="f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"

PASS=0; FAIL=0
pass() { echo "PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }

echo "── build opc-frontdoor (${IMAGE}) ──"
docker build --target opc-frontdoor -t "$IMAGE" \
  -f upstream/buzz/opc/Dockerfile upstream/buzz

echo "── run helper through stdin (--network none) ──"
out="$(mktemp)"; err="$(mktemp)"
run_helper() { # run_helper <agent-pubkey> <expected-owner-pubkey> <secret>
  set +e
  printf '%s\n' "$3" | docker run --rm -i --network none \
    --entrypoint /usr/local/bin/opc-nip-oa-sign "$IMAGE" \
    "$1" "$2" >"$out" 2>"$err"
  rc=$?
  set -e
}

# Happy path: owner secret 1 must sign for agent 2 and match owner 79be667e…
run_helper "$AGENT_PUBKEY" "$OWNER_PUBKEY" "$OWNER_SECRET"
if [ "$rc" -eq 0 ]; then pass "exit 0 (owner secret 1, agent 2)"; else fail "exit $rc (want 0): $(cat "$err")"; fi

tag="$(cat "$out")"
if printf '%s' "$tag" | jq -e --arg owner "$OWNER_PUBKEY" \
    '.[0] == "auth" and .[1] == $owner and .[2] == "" and (.[3] | length == 128)' >/dev/null; then
  pass "tag shape ['auth', owner, '', sig(128 hex)]"
else
  fail "tag shape: $(cat "$out")"
fi
case "$(cat "$out" "$err")" in
  *"$OWNER_SECRET"*) fail "owner secret leaked into stdout/stderr" ;;
  *) pass "no owner secret in stdout/stderr (happy path)" ;;
esac

# Mismatch: secret 1 against expected pubkey of secret 3 → exit 3.
run_helper "$AGENT_PUBKEY" "$MISMATCH_PUBKEY" "$OWNER_SECRET"
if [ "$rc" -eq 3 ]; then pass "owner mismatch exits 3"; else fail "mismatch exit $rc (want 3): $(cat "$err")"; fi
case "$(cat "$out" "$err")" in
  *"$OWNER_SECRET"*) fail "owner secret leaked into stdout/stderr (mismatch)" ;;
  *) pass "no owner secret in stdout/stderr (mismatch path)" ;;
esac

rm -f "$out" "$err"

echo
echo "result: ${PASS} pass, ${FAIL} fail"
[ "$FAIL" = 0 ]
