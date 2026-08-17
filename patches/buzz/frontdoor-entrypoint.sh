#!/bin/sh
# Front-door entrypoint: buzz-acp + Hermes ACP.
# Seeds nix, loads the agent Nostr identity, seeds a Hermes config with the
# Kanban toolset + dispatcher OFF (OPC authority matrix: Paperclip is the
# only durable work plane) and model = OpenCode Go, then execs buzz-acp.
set -eu

. /usr/local/bin/opc-nix-seed.sh
opc_nix_seed

# Mise toolchains: node@lts + rust@stable + omp on the *-mise volume.
. /usr/local/bin/opc-mise-seed.sh
opc_mise_seed

. /usr/local/bin/opc-gh-seed.sh
opc_gh_seed

export BUZZ_PRIVATE_KEY="$(cat "${BUZZ_KEYS_DIR:-/keys}/agent.nsec")"
# ACP observer frames (the desktop's live agent transcript) are encrypted to
# the agent owner. The owner is the human who owns the agent (set via
# BUZZ_ACP_AGENT_OWNER in .env / compose, matching the relay's
# agent_owner_pubkey); fall back to the relay/owner key when unset. Without
# an owner, buzz-acp logs "relay observer requested but no agent owner was
# resolved" and never publishes frames — the desktop shows "No ACP activity
# yet" while the agent works (BUZZ_ACP_RELAY_OBSERVER=true is set in compose).
if [ -z "${BUZZ_ACP_AGENT_OWNER:-}" ] && [ -f "${BUZZ_KEYS_DIR:-/keys}/relay.pub" ]; then
    export BUZZ_ACP_AGENT_OWNER="$(cat "${BUZZ_KEYS_DIR:-/keys}/relay.pub")"
    echo "[frontdoor] ACP agent owner fallback: ${BUZZ_ACP_AGENT_OWNER}"
fi
# Paperclip board API key written by the paperclip-bootstrap one-shot
# (compose PAPERCLIP_API_KEY env remains an override).
if [ -f "${BUZZ_KEYS_DIR:-/keys}/paperclip-api.key" ]; then
    export PAPERCLIP_API_KEY="$(cat "${BUZZ_KEYS_DIR:-/keys}/paperclip-api.key")"
    echo "[frontdoor] PAPERCLIP_API_KEY loaded from keys volume"
fi
# TencentDB admin user_id written by the tencentdb-bootstrap one-shot: scopes
# the agent's memory writes (L0/L1) under the panel owner so the Memory Hub
# panel at 8125 can render them (the panel queries with asset.owner_user_id).
if [ -f "${BUZZ_KEYS_DIR:-/keys}/tencentdb-admin-user-id" ]; then
    export MEMORY_TENCENTDB_USER_ID="$(cat "${BUZZ_KEYS_DIR:-/keys}/tencentdb-admin-user-id")"
    echo "[frontdoor] MEMORY_TENCENTDB_USER_ID loaded from keys volume"
fi
: "${BUZZ_RELAY_URL:=ws://buzz:3000}"
: "${BUZZ_ACP_AGENT_COMMAND:=hermes}"
: "${BUZZ_ACP_AGENT_ARGS:=acp}"
export BUZZ_RELAY_URL BUZZ_ACP_AGENT_COMMAND BUZZ_ACP_AGENT_ARGS
# Persist the resolved relay URL for the issue watcher (the agent's terminal
# children get a sanitized env without it).
mkdir -p /opt/data
printf '%s' "$BUZZ_RELAY_URL" > /opt/data/buzz-relay-url
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
    # Runtime user must own the seeded tree: the shared $HERMES_HOME lives
    # with the hermes runtime (uid HERMES_UID/10000); root-owned plugins/
    # skills make the dashboard show no skills and skill-hub ops EACCES.
    chown -R "${HERMES_UID:-10000}:${HERMES_GID:-10000}" "$HH/plugins" 2>/dev/null || true
    echo "[frontdoor] synced memory provider: memory_tencentdb"
fi

if [ ! -f "$HH/config.yaml" ]; then
    mkdir -p "$HH"
    cat > "$HH/config.yaml" <<YAML
_config_version: 34
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
    # Pre-s12 configs (no _config_version) trip hermes's "predates version
    # 12" migration refusal on every boot; stamp the current version once.
    if ! grep -q "^_config_version:" "$HH/config.yaml"; then
        sed -i "1i _config_version: 34" "$HH/config.yaml"
        echo "[frontdoor] stamped _config_version: 34 onto existing $HH/config.yaml"
    fi
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
    # See MP block above: hermes runtime must own skills/ to run the
    # bundled-skill sync and the skill hub (.hub/lock.json).
    chown -R "${HERMES_UID:-10000}:${HERMES_GID:-10000}" "$HH/skills" 2>/dev/null || true
    echo "[frontdoor] synced skill: paperclip-api"
fi

# Re-attach paperclip issue watchers after a restart (self-heal). The watcher
# posts GitHub links to Buzz when tickets complete; spawned per ticket by the
# agent, re-attached here for any that survived the restart.
mkdir -p /opt/data/issue-watchers
/usr/local/bin/opc-issue-watcher.sh sweep >> /opt/data/issue-watchers/sweep.log 2>&1 &

# Mirror buzz-acp's own logs (Rust tracing, incl. `acp::thought` reasoning
# enabled via RUST_LOG) AND the ACP agent's python stderr logs into the shared
# hermes home's agent.log, so the hermes dashboard Logs page
# (/api/logs?file=agent) shows live agent activity. stdbuf -oL keeps the file
# line-buffered. Note: this makes buzz-acp a pipeline member instead of PID 1 —
# `docker compose stop` may hard-kill it; sessions persist per-turn in
# state.db, so no data is lost.
exec /usr/local/bin/buzz-acp "$@" 2>&1 | stdbuf -oL tee -a "$HH/logs/agent.log"
