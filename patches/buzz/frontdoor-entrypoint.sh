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
# Bootstrap one-shots write /keys/paperclip-api.key (paperclip-bootstrap) and
# /keys/tencentdb-admin-user-id (tencentdb-bootstrap) after `docker compose
# down -v`. A container that boots before its one-shot finishes would run with
# empty PAPERCLIP_API_KEY — the paperclip skill then gets
# 403 "Board access required" on every call and looks like a dead integration.
# compose depends_on orders services; this bounded wait covers manual
# / --no-deps / recreated-container starts where the file may lag the process.
wait_for_keys() {
    missing=""
    for f in "$@"; do
        [ -s "$f" ] || missing="$missing $f"
    done
    [ -z "$missing" ] && return 0
    echo "[frontdoor] waiting for key file(s):$missing (bootstrap one-shot)…"
    n=0
    while [ "$n" -lt 90 ]; do
        n=$((n + 1))
        sleep 2
        missing=""
        for f in "$@"; do
            [ -s "$f" ] || missing="$missing $f"
        done
        [ -z "$missing" ] && { echo "[frontdoor] key files ready after $((n * 2))s"; return 0; }
    done
    echo "[frontdoor] WARNING: key files still missing after 180s:$missing — paperclip/memory integrations unavailable"
    return 1
}
wait_for_keys "${BUZZ_KEYS_DIR:-/keys}/paperclip-api.key" "${BUZZ_KEYS_DIR:-/keys}/tencentdb-admin-user-id"

# Paperclip board API key written by the paperclip-bootstrap one-shot: the
# keys volume is the single source of truth (no .env variable anymore).
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
# opc-hermes-acp.sh wrapper (installed as /usr/local/libexec/hermes): drops
# the spawned agent from root to the hermes runtime uid (10000) so the
# shared home stays single-owner; basename keeps buzz-acp's harness
# identity "hermes" (observer frames + HERMES_ACP_SKIP_CONFIGURED_MCP).
: "${BUZZ_ACP_AGENT_COMMAND:=/usr/local/libexec/hermes}"
: "${BUZZ_ACP_AGENT_ARGS:=acp}"
export BUZZ_RELAY_URL BUZZ_ACP_AGENT_COMMAND BUZZ_ACP_AGENT_ARGS
# Persist the resolved relay URL for the issue watcher (the agent's terminal
# children get a sanitized env without it).
mkdir -p /opt/data
printf '%s' "$BUZZ_RELAY_URL" > /opt/data/buzz-relay-url
echo "[frontdoor] relay=${BUZZ_RELAY_URL} agent=${BUZZ_ACP_AGENT_COMMAND} ${BUZZ_ACP_AGENT_ARGS}"

# The agent replies in channels by running the buzz CLI, but hermes scrubs
# BUZZ_PRIVATE_KEY/BUZZ_RELAY_URL from tool subprocess env (GHSA-rhgp-j443-
# p4rf: provider credentials never reach terminal/execute_code children), so
# the CLI can't authenticate. Wrap /usr/local/bin/buzz to inject the agent
# identity at runtime; terminal children (uid 10000) read the key copy in
# $HERMES_HOME/.agent.nsec (the /keys volume is read-only, so the entrypoint
# copies it there below).
if [ ! -f /usr/local/bin/buzz.bin ]; then
    mv /usr/local/bin/buzz /usr/local/bin/buzz.bin
fi
cat > /usr/local/bin/buzz <<EOF
#!/bin/sh
export BUZZ_PRIVATE_KEY="\${BUZZ_PRIVATE_KEY:-\$(cat "\${HERMES_HOME:-/opt/data}/.agent.nsec" 2>/dev/null)}"
export BUZZ_RELAY_URL="\${BUZZ_RELAY_URL:-$BUZZ_RELAY_URL}"
exec /usr/local/bin/buzz.bin "\$@"
EOF
chmod +x /usr/local/bin/buzz
echo "[frontdoor] buzz wrapper installed (agent identity for CLI)"

HH="${HERMES_HOME:-/opt/data}"

# The ACP agent runs with HOME=$HERMES_HOME (set in opc-hermes-acp.sh), so
# its omp config must live in the home: the nix seed writes /root/.omp
# (entrypoint HOME) which the agent cannot see. Seed once, like the nix
# seed does; the final whole-home chown below fixes ownership.
if [ ! -f "$HH/.omp/agent/config.yml" ]; then
    mkdir -p "$HH/.omp/agent"
    cat > "$HH/.omp/agent/config.yml" <<YAML
modelRoles:
  default: opencode-go/${OPENCODE_GO_MODEL:-deepseek-v4-flash}
startup:
  quiet: true
YAML
    echo "[frontdoor] seeded $HH/.omp/agent/config.yml (omp model=${OPENCODE_GO_MODEL:-deepseek-v4-flash})"
fi

# Runtime-uid key copy for the buzz wrapper: /keys is mounted read-only, so
# the agent's terminal children (uid 10000) cannot read the 600-root key
# file there. Drop a copy into the shared home, owned by the runtime uid.
if [ -f "${BUZZ_KEYS_DIR:-/keys}/agent.nsec" ]; then
    mkdir -p "$HH"
    cp "${BUZZ_KEYS_DIR:-/keys}/agent.nsec" "$HH/.agent.nsec"
    chown "${HERMES_UID:-10000}:${HERMES_GID:-10000}" "$HH/.agent.nsec" 2>/dev/null || true
    chmod 600 "$HH/.agent.nsec"
    echo "[frontdoor] agent key copied to $HH/.agent.nsec for runtime uid"
fi

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
_config_version: 34
agent:
  disabled_toolsets:
    - kanban
  # Conversational default: answer directly; do NOT explore the environment
  # or run other tools unless the user explicitly asks. Reply text alone is
  # never delivered to Buzz — the agent MUST post its answer via the Buzz CLI
  # (buzz messages send --reply-to EVENT_ID; the harness supplies the
  # event_id to anchor to).
  system_prompt: "You are a conversational chat assistant in the Buzz workspace. Reply directly and concisely, in the user's language. IMPORTANT: post every reply to the channel with the Buzz CLI: buzz messages send --reply-to EVENT_ID --content 'TEXT' (the event_id to anchor to is given in the context; omit --reply-to only for channel-root/broadcast posts). Do NOT explore the environment, read files, or run other tools unless the user explicitly asks you to."
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
    echo "[frontdoor] synced skill: paperclip-api"
fi

# Re-attach paperclip issue watchers after a restart (self-heal). The watcher
# posts GitHub links to Buzz when tickets complete; spawned per ticket by the
# agent, re-attached here for any that survived the restart.
mkdir -p /opt/data/issue-watchers
/usr/local/bin/opc-issue-watcher.sh sweep >> /opt/data/issue-watchers/sweep.log 2>&1 &

# Single-owner shared home: every hermes process touching this volume runs
# as uid 10000 (the ACP agent via the setpriv wrapper, and hermes-dashboard).
# All root entrypoint seeds above land before this line; any root-owned
# leftovers from earlier boots (state.db, -wal/-shm, sessions/, cache/) are
# read-only for uid 10000 — SQLite WAL cannot be shared across two unix
# users, so a root-owned state.db trips hermes's writability preflight and
# spams "TUI session store unavailable" while the dashboard loses its
# Sessions/Chat features. Root-created artifacts written after this line
# (issue-watcher sweep.log) are harmless diagnostics.
chown -R "${HERMES_UID:-10000}:${HERMES_GID:-10000}" "$HH" 2>/dev/null || true

# Mirror buzz-acp's own logs (Rust tracing, incl. `acp::thought` reasoning
# enabled via RUST_LOG) AND the ACP agent's python stderr logs into the shared
# hermes home's agent.log, so the hermes dashboard Logs page
# (/api/logs?file=agent) shows live agent activity. stdbuf -oL keeps the file
# line-buffered. Note: this makes buzz-acp a pipeline member instead of PID 1 —
# `docker compose stop` may hard-kill it; sessions persist per-turn in
# state.db, so no data is lost.
exec /usr/local/bin/buzz-acp "$@" 2>&1 | stdbuf -oL tee -a "$HH/logs/agent.log"
