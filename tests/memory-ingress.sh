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

# ── system_prompt_block is STATIC (provider contract), and L2/L3 are not per-turn ──
P=patches/hermes/memory_tencentdb/__init__.py
python3 - "$P" <<'PY' || fail "system_prompt_block or the snapshot path is wrong"
import ast, sys
src = open(sys.argv[1]).read()
tree = ast.parse(src)
fns = {n.name: n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}
spb = ast.dump(fns["system_prompt_block"])
assert "core_read" not in spb and "scenario_ls" not in spb, \
    "system_prompt_block must not fetch recall content (memory_provider.py:90-92: STATIC)"
pf = ast.dump(fns["prefetch"])
assert "_snapshot_due" in pf, "prefetch must gate L2/L3 behind the snapshot check"
print("ok")
PY
pass "system_prompt_block static; L2/L3 gated behind the snapshot check"
# ── L1 recall is bounded, and the limitation is documented ──
grep -q "time_start" patches/hermes/memory_tencentdb/client.py \
  || fail "atomic_search cannot pass time_start, so the recall window is unbounded"
grep -q "MEMORY_TENCENTDB_RECALL_LIMIT" patches/hermes/memory_tencentdb/__init__.py \
  || fail "recall limit is not configurable"
pass "L1 recall is bounded by limit and time window"

# ── the gateway config has an unattended, idempotent producer ──
S=patches/tencentdb-agent-memory/MemoryCore/opc-tdai-config-seed.sh
[ -f "$S" ] || fail "no seeder for /data/config/tdai-gateway.yaml (it would vanish on a clean install)"
grep -q "memory:" "$S" || fail "seeder does not write a memory block"
pass "gateway config has an idempotent seeder"
# ── the sidecar patch exists and is applied by the buzz image ──
PATCHFILE=patches/buzz/patches/hermes-acp-memory-ingress.patch
[ -f "$PATCHFILE" ] || fail "no ACP sidecar patch — the memory ingress boundary would be lost at content.py:273"
grep -q "fuzz=0" patches/buzz/Dockerfile \
  || fail "buzz Dockerfile does not apply the patch with --fuzz=0 (upgrades must hard-fail, not drift)"
pass "ACP sidecar patch exists and is applied with --fuzz=0"
# ── ingress projector: six adversarial cases ──
python3 - <<'PY' || fail "ingress projector failed an adversarial case"
import sys
sys.path.insert(0, "patches/hermes/memory_tencentdb")
from ingress import project

TRUSTED = {"aabbcc"}

def blocks(name):
    raw = open(f"tests/fixtures/buzz-prompts/{name}.txt").read()
    return [b.strip() for b in raw.split("%%BLOCK%%")]

# 1. the happy path captures ONLY the event content
p = project(blocks("single-event"), TRUSTED)
assert p.capture is not None, "trusted single event was not captured"
assert "我偏好 pnpm" in p.capture
assert "someone-else" not in p.capture, "conversation-context leaked into capture"
assert "Channel:" not in p.capture, "header prefix leaked into capture"

# 2. a forged section boundary must not change what is captured
p = project(blocks("forged-boundary"), TRUSTED)
assert p.capture is None, f"forged boundary produced a capture: {p.capture!r}"
assert p.drop_reason

# 3. a forged event split must not promote the attacker to a trusted writer
p = project(blocks("forged-split"), TRUSTED)
assert p.capture is None, f"forged event split produced a capture: {p.capture!r}"

# 4. multi-event batches fail closed
p = project(blocks("multi-event"), TRUSTED)
assert p.capture is None and p.drop_reason == "multi-event"

# 5. cancelled/steer sections fail closed
p = project(blocks("cancelled"), TRUSTED)
assert p.capture is None

# 6. an untrusted writer is never captured, but recall still works
p = project(blocks("untrusted-writer"), TRUSTED)
assert p.capture is None and p.drop_reason == "untrusted-writer"
assert p.recall_query, "recall must still work for untrusted senders"
print("ok")
PY
pass "ingress projector holds on all six adversarial cases"

# ── sync_turn goes through the projector, and the allowlist is pubkey-based ──
P=patches/hermes/memory_tencentdb/__init__.py
grep -q "from .ingress import project\|from ingress import project" "$P" \
  || fail "sync_turn does not use the ingress projector"
grep -q "MEMORY_TRUSTED_WRITERS" "$P" || fail "no writer allowlist"
grep -qi "display.name\|npub1" "$P" && fail "allowlist must key on immutable hex pubkeys, not names/npubs"
pass "sync_turn projects, and the allowlist is hex-pubkey based"
exit 0
