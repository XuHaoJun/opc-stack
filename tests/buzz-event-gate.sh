#!/usr/bin/env bash
# Gate for the two Buzz patches the event loop depends on:
#   opc-event-tag-cli.patch  — `buzz messages send --tag K=V`
#   opc-event-gate.patch     — buzz-acp dedupe + author gate + agent-chatter gate
#
# The *unit* tests run inside the image build (cargo test, same precedent as the
# memory-ingress patch). This script proves the build actually ran them and that
# the artefact carries the change — a patch that applies but is not referenced
# would still produce a clean build.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL  $*" >&2; exit 1; }
pass() { echo "PASS  $*"; }

grep -q "opc-event-tag-cli.patch" patches/buzz/Dockerfile || fail "Dockerfile does not apply the CLI tag patch"
grep -q "opc-event-gate.patch" patches/buzz/Dockerfile || fail "Dockerfile does not apply the gate patch"
grep -q "cargo test --release --locked -p buzz-cli opc_tag_tests" patches/buzz/Dockerfile \
  || fail "Dockerfile does not run the CLI tag unit tests"
grep -q "cargo test --release --locked -p buzz-acp opc_event_gate_tests" patches/buzz/Dockerfile \
  || fail "Dockerfile does not run the gate unit tests"
grep -q "patch -p1 --fuzz=0" patches/buzz/Dockerfile || fail "patches must fail the build on upstream drift"
pass "Dockerfile applies both patches with --fuzz=0 and runs both unit suites"

# grep -q closes the pipe early, and `set -o pipefail` would then read the
# upstream SIGPIPE as a failure (the same trap scripts/prepare.sh documents).
# Count matches instead: grep -c drains its input.
TAG_LINES="$(docker compose exec -T frontdoor buzz messages send --help 2>/dev/null | grep -c -- "--tag <KEY=VALUE>" || true)"
[ "${TAG_LINES:-0}" -ge 1 ] || fail "running buzz CLI has no --tag flag"
pass "running CLI exposes --tag"

GATE_LINES="$(docker compose exec -T frontdoor sh -c 'strings /usr/local/bin/buzz-acp' | grep -c "opc event gate" || true)"
[ "${GATE_LINES:-0}" -ge 1 ] || fail "running buzz-acp has no gate (patch not in the artefact)"
pass "running buzz-acp carries the gate"
