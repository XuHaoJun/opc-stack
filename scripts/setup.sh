#!/usr/bin/env bash
# One-command bring-up on a fresh machine:
#   git clone <this repo> && cd <repo> && scripts/setup.sh
#
# Does: .env bootstrap → submodule init → apply patches → build → up.
# Afterwards run tests/connectivity.sh to verify the stack.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "── [1/5] .env ──"
if [ ! -f .env ]; then
  cp .env.example .env
  echo "created .env from .env.example"
  echo "⚠  EDIT .env NOW:"
  echo "    1. OPENAI_API_KEY  (one key powers the whole stack)"
  echo "    2. BUZZ_RELAY_URL    (REQUIRED: set to this machine's LAN/tailnet IP,"
  echo "                          e.g. ws://192.168.1.10:3000. The localhost"
  echo "                          default only works for clients sharing the"
  echo "                          relay's netns; the expert agents in the hermes"
  echo "                          container do not, so their Buzz posts go"
  echo "                          nowhere — and the relay rejects a non-canonical"
  echo "                          host silently)"
  echo "  then re-run scripts/setup.sh (or continue below; .env is re-read every run)."
fi
# Warn while BUZZ_RELAY_URL still points at localhost (not usable for the
# expert agents; see .env.example).
. "$(dirname "$0")/load-env.sh"; opc_load_env ./.env
if [[ "${BUZZ_RELAY_URL:-}" == "ws://localhost"* ]]; then
  echo "⚠  BUZZ_RELAY_URL is still ws://localhost:3000 — expert agents (hermes"
  echo "   container) cannot reach the relay there, and the relay rejects a"
  echo "   non-canonical host with no error. Set it to a routable address."
  if command -v hostname >/dev/null; then
    lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -n "$lan_ip" ] && echo "   hint: LAN IP is ${lan_ip} — BUZZ_RELAY_URL=ws://${lan_ip}:3000"
  fi
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
echo "  tests/connectivity.sh"
