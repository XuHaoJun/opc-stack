#!/bin/sh
# Hermes entrypoint: seed the /nix volume, seed an OPC config (kanban toolset
# + dispatcher OFF — Paperclip is the canonical work plane; model = OpenCode
# Go custom OpenAI-compatible endpoint), then hand off to the upstream s6
# entrypoint dispatcher.
set -eu

. /usr/local/bin/opc-nix-seed.sh
opc_nix_seed

. /usr/local/bin/opc-gh-seed.sh
opc_gh_seed

HH="${HERMES_HOME:-/opt/data}"

# TencentDB Knowledge Plane (PRD v10.1): sync the memory_tencentdb Hermes
# MemoryProvider into $HERMES_HOME/plugins/ (user-plugin discovery path) on
# every boot — image updates propagate into existing volumes.
MP_SRC="/opt/hermes/memory_tencentdb"
MP_DST="$HH/plugins/memory_tencentdb"
if [ -d "$MP_SRC" ]; then
    mkdir -p "$HH/plugins"
    rm -rf "$MP_DST"
    cp -r "$MP_SRC" "$MP_DST"
    echo "[hermes] synced memory provider: memory_tencentdb"
fi

# paperclip-api skill (GitHub integration): sync from image on every boot.
SK_SRC="/opt/hermes/skills/paperclip-api"
SK_DST="$HH/skills/paperclip-api"
if [ -d "$SK_SRC" ]; then
    mkdir -p "$HH/skills"
    rm -rf "$SK_DST"
    cp -r "$SK_SRC" "$SK_DST"
    echo "[hermes] synced skill: paperclip-api"
fi

if [ ! -f "$HH/config.yaml" ]; then
    mkdir -p "$HH"
    cat > "$HH/config.yaml" <<YAML
agent:
  disabled_toolsets:
    - kanban
kanban:
  dispatch_in_gateway: false
  review_dispatch: false
  auto_decompose: false
memory:
  provider: memory_tencentdb
model:
  provider: custom
  base_url: ${OPENCODE_GO_BASE_URL:-https://opencode.ai/zen/go/v1}
  default: ${OPENCODE_GO_MODEL:-deepseek-v4-flash}
YAML
    echo "[hermes] seeded $HH/config.yaml (kanban disabled; memory=tencentdb; model=${OPENCODE_GO_MODEL:-deepseek-v4-flash})"
fi

# Refresh seeded model lines on existing volumes that still carry the legacy
# hardcoded default (config.yaml is dashboard-editable afterwards; only the
# exact legacy values are rewritten, not user edits).
if [ -f "$HH/config.yaml" ]; then
    sed -i "s|^  default: deepseek-v4-pro$|  default: ${OPENCODE_GO_MODEL:-deepseek-v4-flash}|; s|^  base_url: https://opencode\\.ai/zen/go/v1$|  base_url: ${OPENCODE_GO_BASE_URL:-https://opencode.ai/zen/go/v1}|" "$HH/config.yaml"
fi

# Key routing: for provider "custom", Hermes reads OPENAI_API_KEY +
# OPENAI_BASE_URL from the environment (or $HERMES_HOME/.env).
: "${OPENAI_API_KEY:=$OPENCODE_API_KEY}"
: "${OPENAI_BASE_URL:=${OPENCODE_GO_BASE_URL:-https://opencode.ai/zen/go/v1}}"
export OPENAI_API_KEY OPENAI_BASE_URL

exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"
