#!/usr/bin/env bash
# Real local-stack regression: deterministic ACP provider, no model calls.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/load-env.sh
opc_load_env ./.env
if [ "${1-}" = --help ]; then
  echo 'usage: tests/paperclip-acp-terminal.sh'
  echo 'Uses the running local Paperclip stack. Creates/deletes one marked fixture agent and two unscoped fresh runs; no LLM, issue, task or production-agent mutation.'
  echo 'Authenticates real terminal consumers against /api/agents/me. Removes only exact owned zero-cost/token accounting; protected accounting remains for the operator.'
  exit 0
fi
[ "$#" -eq 0 ] || { echo 'usage: tests/paperclip-acp-terminal.sh' >&2; exit 2; }
HOST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opc-terminal-authority.XXXXXX")"
CONTAINER_DIR="/tmp/opc-terminal-authority-$(date +%s)-$$-$RANDOM"
chmod 700 "$HOST_DIR"
cleanup() {
  local status=$?
  trap - EXIT
  # Only fixture scripts/state in our freshly created directory; never server logs.
  docker compose cp "paperclip:$CONTAINER_DIR/evidence.json" "$HOST_DIR/evidence.json" >/dev/null 2>&1 || true
  if ! docker compose exec -T paperclip rm -rf -- "$CONTAINER_DIR"; then
    echo 'FAIL  remove owned fixture scripts/state' >&2
    status=1
  fi
  if [ "$status" -eq 0 ]; then
    rm -rf -- "$HOST_DIR"
  else
    echo "INFO  safe fixture evidence retained: $HOST_DIR/evidence.json" >&2
  fi
  exit "$status"
}
trap cleanup EXIT
# Defer interruption until the bounded driver drains/deletes its own runs.
# Killing docker exec early would strand an agent while removing its scripts.
trap '' INT TERM
for tool in docker; do command -v "$tool" >/dev/null || { echo "FAIL  missing $tool" >&2; exit 1; }; done
docker compose exec -T -u node paperclip mkdir -m 700 -- "$CONTAINER_DIR"
for name in agent consumer driver; do
  docker compose cp "tests/fixtures/paperclip-terminal-$name.mjs" "paperclip:$CONTAINER_DIR/paperclip-terminal-$name.mjs" >/dev/null
done
echo 'INFO  genuine ACP terminal authority gate: local API only; no provider/model call'
docker compose exec -T -u node \
  -e "OPC_TERMINAL_COMPANY_ID=${OPC_TERMINAL_COMPANY_ID:-}" \
  paperclip node "$CONTAINER_DIR/paperclip-terminal-driver.mjs"
