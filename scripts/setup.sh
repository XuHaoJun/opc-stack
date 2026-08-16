#!/usr/bin/env bash
# One-command bring-up on a fresh machine:
#   git clone <this repo> && cd <repo> && scripts/setup.sh
#
# Does: .env bootstrap → submodule init → apply patches → build → up.
# Afterwards run scripts/test-connectivity.sh to verify the stack.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "── [1/5] .env ──"
if [ ! -f .env ]; then
  cp .env.example .env
  echo "created .env from .env.example"
  echo "⚠  EDIT .env NOW:"
  echo "    1. OPENCODE_API_KEY  (one key powers the whole stack)"
  echo "    2. BUZZ_RELAY_URL    (set to this machine's LAN IP so desktop/phone"
  echo "                          can reach it; default ws://localhost:3000 works"
  echo "                          for same-machine use)"
  echo "  then re-run scripts/setup.sh (or continue below; .env is re-read every run)."
fi
# Show a hint for the relay URL (only when it still points at localhost).
set -a; . ./.env; set +a
if [[ "${BUZZ_RELAY_URL:-}" == "ws://localhost"* ]] && command -v hostname >/dev/null; then
  lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "$lan_ip" ] && echo "hint: LAN IP is ${lan_ip} — set BUZZ_RELAY_URL=ws://${lan_ip}:3000 for device access"
fi

echo "── [2/5] submodules ──"
# Top-level only (--recursive would hit a broken nested submodule in
# upstream tencentdb-agent-memory: MemoryProxy/packages/cost-guard has a
# gitlink but no .gitmodules entry). None of our builds use nested submodules.
git submodule update --init
# Patched opc/ content inside submodule worktrees is untracked by design —
# keep parent `git status` clean instead of showing all 4 submodules dirty.
git config diff.ignoreSubmodules untracked

echo "── [3/5] patches ──"
scripts/prepare.sh

echo "── [4/5] build + up ──"
docker compose up -d --build

echo "── [5/5] done ──"
echo "Stack is up. Verify connectivity:"
echo "  scripts/test-connectivity.sh"
