#!/bin/sh
# Hermes entrypoint: seed the /nix volume, seed an OPC config (kanban toolset
# + dispatcher OFF — Paperclip is the canonical work plane; model = OpenCode
# Go custom OpenAI-compatible endpoint), then hand off to the upstream s6
# entrypoint dispatcher.
set -eu

. /usr/local/bin/opc-nix-seed.sh
opc_nix_seed

HH="${HERMES_HOME:-/opt/data}"
if [ ! -f "$HH/config.yaml" ]; then
    mkdir -p "$HH"
    cat > "$HH/config.yaml" <<'YAML'
agent:
  disabled_toolsets:
    - kanban
kanban:
  dispatch_in_gateway: false
  review_dispatch: false
  auto_decompose: false
model:
  provider: custom
  base_url: https://opencode.ai/zen/go/v1
  default: deepseek-v4-pro
YAML
    echo "[hermes] seeded $HH/config.yaml (kanban disabled; model=OpenCode Go)"
fi

# Key routing: for provider "custom", Hermes reads OPENAI_API_KEY +
# OPENAI_BASE_URL from the environment (or $HERMES_HOME/.env).
: "${OPENAI_API_KEY:=$OPENCODE_API_KEY}"
: "${OPENAI_BASE_URL:=${OPENCODE_GO_BASE_URL:-https://opencode.ai/zen/go/v1}}"
export OPENAI_API_KEY OPENAI_BASE_URL

exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"
