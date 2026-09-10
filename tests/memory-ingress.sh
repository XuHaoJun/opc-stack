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

# ── SOUL.md carries the untrusted-memory rule, in both copies ──
for f in patches/buzz/SOUL.md patches/hermes/SOUL.md; do
  grep -q "不可信的參考資料" "$f" || fail "$f is missing the untrusted-memory rule"
done
pass "both SOUL.md copies carry the untrusted-memory rule"

# ── prepare.sh guards the plugin tree against drift ──
grep -q "check_identical_tree" scripts/prepare.sh \
  || fail "scripts/prepare.sh has no tree drift guard for memory_tencentdb"
pass "prepare.sh guards the memory_tencentdb tree"


# ── recall block carries scope + trust, and never a score ──
P=patches/hermes/memory_tencentdb/__init__.py
grep -q 'trust="untrusted-reference"' "$P" || fail "recall block has no trust attribute"
grep -q 'scope=' "$P" || fail "recall block has no scope attribute"
grep -q "[\"']score[\"']" "$P" && fail "recall block still references score (it is an RRF rank, not a similarity)"
pass "recall block carries scope + trust and no score"
exit 0
