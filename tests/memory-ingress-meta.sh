#!/bin/sh
# Offline gate for the Buzz half of the memory-ingress wire contract
# (docs/superpowers/specs/2026-09-11-memory-ingress-structural-provenance.md §3).
#
# Takes the buzz submodule as it stands, applies
# patches/buzz/patches/opc-memory-ingress-meta.patch to a scratch clone with
# --fuzz=0, runs the patched patch's own tests, and deep-compares the `_meta`
# they dumped against the golden payloads in tests/fixtures/. No stack, no relay,
# no network beyond the cargo registry.
#
# The comparison is the point: the golden file lives in THIS repo, while the
# Rust tests run inside the buzz build (which cannot see this repo at all), so
# the dump is the only place the two halves of the contract meet. What is
# compared is structure and metadata — never the rendered prompt text, which is
# Buzz's own business (the fixture's texts are illustrative and are not
# reproduced by the code).
set -eu
cd "$(dirname "$0")/.."

fail() { echo "FAIL  $1"; exit 1; }
pass() { echo "ok    $1"; }

SUBMODULE=upstream/buzz
PATCHFILE=patches/buzz/patches/opc-memory-ingress-meta.patch
FIXTURE=tests/fixtures/buzz-acp-prompt-blocks.json
FILTER=memory_ingress_meta_tests

# ── prerequisites ──────────────────────────────────────────────────────────
# Missing toolchain is a hard failure, not a skip: this gate's whole job is to
# compile the patched crate, and a silent skip would read as a pass.
command -v cargo >/dev/null 2>&1 \
  || fail "cargo is not on PATH — this gate compiles the patched buzz-acp (rustup/cargo required)"
command -v patch >/dev/null 2>&1 \
  || fail "patch is not on PATH — the buzz overlay cannot be applied"
command -v python3 >/dev/null 2>&1 \
  || fail "python3 is not on PATH — the fixture comparison cannot run"
[ -d "$SUBMODULE/.git" ] || [ -f "$SUBMODULE/.git" ] \
  || fail "$SUBMODULE is not a git checkout — run 'git submodule update --init' first"
[ -f "$PATCHFILE" ] || fail "missing overlay patch: $PATCHFILE"
[ -f "$FIXTURE" ] || fail "missing golden payloads: $FIXTURE"
PATCH_ABS="$PWD/$PATCHFILE"
FIXTURE_ABS="$PWD/$FIXTURE"
pass "prerequisites present (cargo, patch, python3, $SUBMODULE)"

# The build dir is reused across runs (a cold release build of the crate is
# minutes, a warm one seconds). Override with CARGO_TARGET_DIR to point it
# somewhere disposable; the patched tests also write their dump there, which is
# how this script finds it.
TARGET_DIR="${CARGO_TARGET_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/opc-memory-ingress-meta}"
mkdir -p "$TARGET_DIR" || fail "cannot create build dir $TARGET_DIR"
export CARGO_TARGET_DIR="$TARGET_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── scratch clone at the pinned commit (never edit the submodule) ──────────
PINNED="$(git -C "$SUBMODULE" rev-parse HEAD)"
git -c advice.detachedHead=false clone --quiet --shared "$SUBMODULE" "$WORK/src" \
  || fail "cannot clone $SUBMODULE"
git -c advice.detachedHead=false -C "$WORK/src" checkout --quiet -f "$PINNED" \
  || fail "cannot check out $PINNED in the scratch clone"
pass "scratch clone at $(echo "$PINNED" | cut -c1-12)"

# ── apply the overlay exactly the way the image build does ─────────────────
# --fuzz=0: upstream drift must stop the build, not drift silently.
(cd "$WORK/src" && patch -p1 --fuzz=0 --no-backup-if-mismatch < "$PATCH_ABS") >"$WORK/patch.log" 2>&1 \
  || { cat "$WORK/patch.log"; fail "$PATCHFILE does not apply to $PINNED with --fuzz=0"; }
pass "overlay applies with --fuzz=0"

# ── the patched crate's own tests (the ones the image build runs) ──────────
# Delete the dump first: the comparison must read what THIS run wrote, not a
# leftover from a previous one.
DUMP="$TARGET_DIR/opc-memory-ingress-dump.json"
rm -f "$DUMP"
(cd "$WORK/src" && cargo test --release --locked -p buzz-acp "$FILTER") >"$WORK/cargo.log" 2>&1 \
  || { tail -60 "$WORK/cargo.log"; fail "cargo test --release --locked -p buzz-acp $FILTER failed"; }
grep -q "test result: ok" "$WORK/cargo.log" \
  || { tail -60 "$WORK/cargo.log"; fail "cargo reported no passing tests for $FILTER"; }
pass "cargo test -p buzz-acp $FILTER ($(grep -c '^test .* ok$' "$WORK/cargo.log") tests)"

[ -f "$DUMP" ] \
  || fail "the tests did not write $DUMP — the fixture comparison has nothing to read"
pass "dump written to $DUMP"

# ── deep-compare the dump against the golden payloads ──────────────────────
# Block count and `_meta`, per scenario and per block index. Text is never
# compared. A block the fixture leaves bare must carry no `_meta` KEY at all
# (`null` is a different claim).
python3 - "$FIXTURE_ABS" "$DUMP" <<'PY' || exit 1
import json
import sys

fixture_path, dump_path = sys.argv[1], sys.argv[2]
try:
    fixture = json.load(open(fixture_path, encoding="utf-8"))["scenarios"]
    dump = json.load(open(dump_path, encoding="utf-8"))["scenarios"]
except (OSError, ValueError, KeyError) as exc:
    print(f"FAIL  cannot read the golden payloads or the dump: {exc}")
    raise SystemExit(1)

problems = []


def compare(name, want_blocks, got_blocks):
    # The fixture lists the prompt from the first section that matters to the end:
    # `format_prompt` always emits the `<context>` section, and the hand-authored
    # golden omits it in the two scenarios it authored without channel info. So
    # the dump is allowed to lead with at most one bare block — and that block
    # must carry no metadata, since it is exactly the section the fixture skipped.
    trim = len(got_blocks) - len(want_blocks)
    if trim < 0:
        problems.append(
            f"{name}: dump has {len(got_blocks)} blocks, the fixture has {len(want_blocks)}"
        )
        return
    if trim > 1:
        problems.append(f"{name}: dump leads the fixture by {trim} blocks, expected at most 1")
        return
    for i in range(trim):
        if "_meta" in got_blocks[i]:
            problems.append(
                f"{name}: block {i} leads the fixture and carries `_meta` — the alignment is wrong"
            )
            return
    for i, want in enumerate(want_blocks):
        got = got_blocks[trim + i]
        if got.get("type") != "text":
            problems.append(f"{name}: block {i} is not a text block ({got.get('type')!r})")
        if ("_meta" in got) != ("_meta" in want):
            problems.append(
                f"{name}: block {i} {'carries' if '_meta' in got else 'is missing'} `_meta`, "
                f"the fixture says otherwise"
            )
            continue
        if got.get("_meta") != want.get("_meta"):
            problems.append(f"{name}: block {i} `_meta` differs from the fixture")
            print(f"        want: {json.dumps(want.get('_meta'), ensure_ascii=False)}")
            print(f"        got:  {json.dumps(got.get('_meta'), ensure_ascii=False)}")
    if not any(p.startswith(name + ":") for p in problems):
        carried = sum(1 for b in want_blocks if "_meta" in b)
        print(f"ok    {name}: {len(want_blocks)} blocks compared, {carried} carrying `_meta`")


for name, scenario in fixture.items():
    if name not in dump:
        problems.append(f"{name}: the fixture has this scenario, the dump does not")
        continue
    compare(name, scenario["prompt"], dump[name]["prompt"])

for name in dump:
    if name not in fixture:
        problems.append(f"{name}: dumped but not in the fixture — the golden has drifted behind")

if problems:
    for problem in problems:
        print(f"FAIL  {problem}")
    raise SystemExit(1)
print("ok    the dump matches the golden `_meta` payloads block for block")
PY

exit 0
