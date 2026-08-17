#!/bin/sh
# Hermes entrypoint: seed the /nix volume, seed an OPC config (kanban toolset
# + dispatcher OFF — Paperclip is the canonical work plane; model = OpenCode
# Go custom OpenAI-compatible endpoint), then hand off to the upstream s6
# entrypoint dispatcher.
set -eu

. /usr/local/bin/opc-nix-seed.sh
opc_nix_seed

# Mise toolchains: node@lts + rust@stable + omp on the *-mise volume.
. /usr/local/bin/opc-mise-seed.sh
opc_mise_seed

. /usr/local/bin/opc-gh-seed.sh
opc_gh_seed

# Paperclip board API key written by the paperclip-bootstrap one-shot
# (compose PAPERCLIP_API_KEY env remains an override).
if [ -f /keys/paperclip-api.key ]; then
    export PAPERCLIP_API_KEY="$(cat /keys/paperclip-api.key)"
    echo "[hermes] PAPERCLIP_API_KEY loaded from keys volume"
fi
# TencentDB admin user_id written by the tencentdb-bootstrap one-shot: scopes
# memory writes (L0/L1) under the panel owner so the Memory Hub panel at 8125
# can render them (the panel queries with asset.owner_user_id).
if [ -f /keys/tencentdb-admin-user-id ]; then
    export MEMORY_TENCENTDB_USER_ID="$(cat /keys/tencentdb-admin-user-id)"
    echo "[hermes] MEMORY_TENCENTDB_USER_ID loaded from keys volume"
fi

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
    # Runtime user must own the seeded tree: s6 stage2 only chowns when the
    # top-level $HERMES_HOME owner is wrong (it isn't — /opt/data is already
    # the runtime uid), so root-owned plugins/skills would survive boot. Then
    # the dashboard shows no skills and skill-hub ops EACCES (bundled-skill
    # sync also fails to write into root-owned skills/).
    chown -R "${HERMES_UID:-10000}:${HERMES_GID:-10000}" "$HH/plugins" 2>/dev/null || true
    echo "[hermes] synced memory provider: memory_tencentdb"
fi

# paperclip-api skill (GitHub integration): sync from image on every boot.
SK_SRC="/opt/hermes/skills/paperclip-api"
SK_DST="$HH/skills/paperclip-api"
if [ -d "$SK_SRC" ]; then
    mkdir -p "$HH/skills"
    rm -rf "$SK_DST"
    cp -r "$SK_SRC" "$SK_DST"
    # See MP block above: hermes runtime must own skills/ to run the
    # bundled-skill sync and the skill hub (.hub/lock.json).
    chown -R "${HERMES_UID:-10000}:${HERMES_GID:-10000}" "$HH/skills" 2>/dev/null || true
    echo "[hermes] synced skill: paperclip-api"
fi

if [ ! -f "$HH/config.yaml" ]; then
    mkdir -p "$HH"
    cat > "$HH/config.yaml" <<YAML
_config_version: 34
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
    # Pre-s12 configs (no _config_version) trip hermes's "predates version
    # 12" migration refusal on every boot; stamp the current version once.
    if ! grep -q "^_config_version:" "$HH/config.yaml"; then
        sed -i "1i _config_version: 34" "$HH/config.yaml"
        echo "[hermes] stamped _config_version: 34 onto existing $HH/config.yaml"
    fi
fi

# Key routing: for provider "custom", Hermes reads OPENAI_API_KEY +
# OPENAI_BASE_URL from the environment (or $HERMES_HOME/.env).
: "${OPENAI_API_KEY:=$OPENCODE_API_KEY}"
: "${OPENAI_BASE_URL:=${OPENCODE_GO_BASE_URL:-https://opencode.ai/zen/go/v1}}"
export OPENAI_API_KEY OPENAI_BASE_URL

exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"
