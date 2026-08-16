#!/bin/sh
# Front-door entrypoint: buzz-acp + Hermes ACP.
# Seeds nix, loads the agent Nostr identity, seeds a Hermes config with the
# Kanban toolset + dispatcher OFF (OPC authority matrix: Paperclip is the
# only durable work plane) and model = OpenCode Go, then execs buzz-acp.
set -eu

. /usr/local/bin/opc-nix-seed.sh
opc_nix_seed

. /usr/local/bin/opc-gh-seed.sh
opc_gh_seed

export BUZZ_PRIVATE_KEY="$(cat "${BUZZ_KEYS_DIR:-/keys}/agent.nsec")"
# Paperclip board API key written by the paperclip-bootstrap one-shot
# (compose PAPERCLIP_API_KEY env remains an override).
if [ -f "${BUZZ_KEYS_DIR:-/keys}/paperclip-api.key" ]; then
    export PAPERCLIP_API_KEY="$(cat "${BUZZ_KEYS_DIR:-/keys}/paperclip-api.key")"
    echo "[frontdoor] PAPERCLIP_API_KEY loaded from keys volume"
fi
: "${BUZZ_RELAY_URL:=ws://buzz:3000}"
: "${BUZZ_ACP_AGENT_COMMAND:=hermes}"
: "${BUZZ_ACP_AGENT_ARGS:=acp}"
export BUZZ_RELAY_URL BUZZ_ACP_AGENT_COMMAND BUZZ_ACP_AGENT_ARGS
echo "[frontdoor] relay=${BUZZ_RELAY_URL} agent=${BUZZ_ACP_AGENT_COMMAND} ${BUZZ_ACP_AGENT_ARGS}"

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
    echo "[frontdoor] synced memory provider: memory_tencentdb"
fi

if [ ! -f "$HH/config.yaml" ]; then
    mkdir -p "$HH"
    cat > "$HH/config.yaml" <<YAML
agent:
  disabled_toolsets:
    - kanban
  # Conversational default: answer directly; do NOT explore the environment
  # or run tools unless the user explicitly asks. (The first turn after a
  # restart does a one-time environment orientation pass — accepted as
  # expected hermes session-init behavior; subsequent turns reply in seconds.)
  system_prompt: "You are a conversational chat assistant in the Buzz workspace. Reply directly, concisely, and in the user's language. Do NOT run tools, explore the environment, read files, or take actions unless the user explicitly asks you to. For greetings, small talk, and questions, just answer in plain text."
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
    echo "[frontdoor] seeded $HH/config.yaml (kanban disabled; memory=tencentdb; model=${OPENCODE_GO_MODEL:-deepseek-v4-flash})"
fi

# Refresh seeded model lines on existing volumes that still carry the legacy
# hardcoded default (config.yaml is dashboard-editable afterwards; only the
# exact legacy values are rewritten, not user edits).
if [ -f "$HH/config.yaml" ]; then
    sed -i "s|^  default: deepseek-v4-pro$|  default: ${OPENCODE_GO_MODEL:-deepseek-v4-flash}|; s|^  base_url: https://opencode\\.ai/zen/go/v1$|  base_url: ${OPENCODE_GO_BASE_URL:-https://opencode.ai/zen/go/v1}|" "$HH/config.yaml"
fi

: "${OPENAI_API_KEY:=$OPENCODE_API_KEY}"
: "${OPENAI_BASE_URL:=${OPENCODE_GO_BASE_URL:-https://opencode.ai/zen/go/v1}}"
export OPENAI_API_KEY OPENAI_BASE_URL

# Self-healing agent registration (profile + channel membership) — runs
# alongside buzz-acp so a fresh deploy needs no manual setup steps.
opc-register-agent.sh &

# paperclip-api skill (GitHub integration): sync from image on every boot —
# image updates propagate into existing volumes.
SK_SRC="/opt/hermes/skills/paperclip-api"
SK_DST="$HH/skills/paperclip-api"
if [ -d "$SK_SRC" ]; then
    mkdir -p "$HH/skills"
    rm -rf "$SK_DST"
    cp -r "$SK_SRC" "$SK_DST"
    echo "[frontdoor] synced skill: paperclip-api"
fi

# Re-attach paperclip issue watchers after a restart (self-heal). The watcher
# posts GitHub links to Buzz when tickets complete; spawned per ticket by the
# agent, re-attached here for any that survived the restart.
mkdir -p /opt/data/issue-watchers
/usr/local/bin/opc-issue-watcher.sh sweep >> /opt/data/issue-watchers/sweep.log 2>&1 &

exec /usr/local/bin/buzz-acp "$@"
