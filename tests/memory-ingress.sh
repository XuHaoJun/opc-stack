#!/bin/sh
# Offline gates for the memory ingress path. No stack, no network.
set -eu
cd "$(dirname "$0")/.."

fail() { echo "FAIL  $1"; exit 1; }
pass() { echo "ok    $1"; }

# ── experiment harness argument validation ──
[ -x scripts/memory-experiment.sh ] || fail "memory-experiment harness missing"
if scripts/memory-experiment.sh provision memtest-a >/dev/null 2>&1; then
  fail "provision accepted an agent id not starting with 'agt'"
fi
pass "provision rejects non-agt agent id"
