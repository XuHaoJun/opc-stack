#!/usr/bin/env bash
# Sync patches/<project>/ onto the submodule checkouts in upstream/.
# Idempotent: safe to run before every build.
#
# Why this exists: all local customizations (custom Dockerfiles, entrypoints,
# one-shot bootstrap scripts) live ONLY in patches/ (version-controlled here).
# upstream/ is clean submodule checkouts — never edit them directly; upgrade
# = checkout a new tag (see scripts/upgrade.sh), then this re-applies.
set -euo pipefail
cd "$(dirname "$0")/.."

apply_patch() {
  local proj="$1"    # path under upstream/, e.g. "buzz" or "tencentdb-agent-memory/MemoryProxy"
  local src="patches/$proj"
  local dst="upstream/$proj"
  if [ ! -d "$src" ]; then
    echo "SKIP  $proj (no patch dir)"
    return
  fi
  if [ ! -d "$dst" ]; then
    echo "FAIL  $proj: upstream/$proj missing — run 'git submodule update --init' first"
    exit 1
  fi
  mkdir -p "$dst"
  rsync -a --delete "$src/" "$dst/"
  echo "SYNC  $proj → $dst"
}

apply_patch buzz
apply_patch hermes
apply_patch paperclip
apply_patch tencentdb-agent-memory
apply_patch tencentdb-agent-memory/MemoryProxy

echo "prepare: done"
