#!/usr/bin/env bash
# Sync patches/<project>/ onto the submodule checkouts in upstream/.
# Idempotent: safe to run before every build.
#
# Why this exists: all local customizations (custom Dockerfiles, entrypoints,
# one-shot bootstrap scripts) live ONLY in patches/ (version-controlled here).
# patches/<proj>/ mirrors the contents of the opc/ dir the repos were
# customized with; prepare copies it onto upstream/<proj>/opc/. upstream/ is
# clean submodule checkouts — never edit them directly; upgrade = checkout a
# new tag (see scripts/upgrade.sh), then this re-applies.
set -euo pipefail
cd "$(dirname "$0")/.."

apply_patch() {
  local proj="$1"    # path under upstream/, e.g. "buzz" or "tencentdb-agent-memory/MemoryProxy"
  local src="patches/$proj"
  local dst="upstream/$proj/opc"
  if [ ! -d "$src" ]; then
    echo "SKIP  $proj (no patch dir)"
    return
  fi
  if [ ! -d "upstream/$proj" ]; then
    echo "FAIL  $proj: upstream/$proj missing — run 'git submodule update --init' first"
    exit 1
  fi
  mkdir -p "$dst"
  rsync -a --delete "$src/" "$dst/"
  echo "SYNC  $proj → $dst"
}

# ── drift guard ─────────────────────────────────────────────────────────
# Some things exist in two copies BY DESIGN, because they must reach two
# different hermes homes (the Buzz front door and the gateway) and each home
# is served by a different image. "Keep these two files identical" is a rule
# that has silently broken three times in this repo, and the failure is
# invisible at runtime: work routes correctly from one surface and not the
# other, depending on where the user happened to type. Cheaper to fail here.
check_identical() {
  local label="$1" a="$2" b="$3"
  if [ ! -f "$a" ] || [ ! -f "$b" ]; then
    echo "FAIL  $label: expected two copies, missing $( [ -f "$a" ] || echo "$a" ) $( [ -f "$b" ] || echo "$b" )"
    exit 1
  fi
  if ! diff -q "$a" "$b" >/dev/null; then
    echo "FAIL  $label: the two copies have drifted — they must be byte-identical"
    diff -u "$a" "$b" | head -40
    exit 1
  fi
  echo "SAME  $label"
}

check_identical "paperclip-api skill" \
  patches/buzz/skills/paperclip-api/SKILL.md \
  patches/hermes/skills/paperclip-api/SKILL.md

# The delegation clause is embedded in each entrypoint's seeded system_prompt
# (it has to hold before any skill loads — see the comment at the seed site),
# so it cannot be a shared file. Compare the extracted sentence instead.
# Anchored on a phrase with no apostrophe: the clause itself contains one
# ("OPC's"), which would terminate a single-quoted sed script.
delegation_clause() {
  grep -o 'chief of staff, not an implementer[^"]*' "$1" | head -1
}
fd_clause="$(delegation_clause patches/buzz/frontdoor-entrypoint.sh)"
gw_clause="$(delegation_clause patches/hermes/hermes-entrypoint.sh)"
if [ -z "$fd_clause" ] || [ -z "$gw_clause" ]; then
  echo "FAIL  delegation clause: not found in both entrypoints"
  exit 1
fi
if [ "$fd_clause" != "$gw_clause" ]; then
  echo "FAIL  delegation clause: front door and gateway have drifted"
  echo "  frontdoor: $fd_clause"
  echo "  gateway:   $gw_clause"
  exit 1
fi
echo "SAME  delegation clause"

apply_patch buzz
apply_patch hermes
apply_patch paperclip
apply_patch tencentdb-agent-memory
apply_patch tencentdb-agent-memory/MemoryProxy
apply_patch tencentdb-agent-memory/MemoryCore

echo "prepare: done"
