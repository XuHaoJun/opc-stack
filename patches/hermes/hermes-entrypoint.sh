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
    echo "[hermes] waiting for key file(s):$missing (bootstrap one-shot)…"
    n=0
    while [ "$n" -lt 90 ]; do
        n=$((n + 1))
        sleep 2
        missing=""
        for f in "$@"; do
            [ -s "$f" ] || missing="$missing $f"
        done
        [ -z "$missing" ] && { echo "[hermes] key files ready after $((n * 2))s"; return 0; }
    done
    echo "[hermes] WARNING: key files still missing after 180s:$missing — paperclip/memory integrations unavailable"
    return 1
}
wait_for_keys /keys/paperclip-api.key /keys/tencentdb-admin-user-id

# Paperclip board API key written by the paperclip-bootstrap one-shot: the
# keys volume is the single source of truth (no .env variable anymore).
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
_config_version: 34
agent:
  disabled_toolsets:
    - kanban
  # Same delegation clause as patches/buzz/frontdoor-entrypoint.sh, and it MUST
  # stay identical (scripts/prepare.sh fails the build if they drift). The
  # dashboard chat is the same agent as the Buzz front door on a different
  # platform adapter, so a rule that holds in one surface and not the other is
  # worse than no rule: work routes correctly or not depending on where the
  # user happened to type. This home had no system_prompt at all before.
  system_prompt: "You are OPC's chief of staff, not an implementer. When the user asks for something to be BUILT or CHANGED in code — an app, a script, a prototype, a bug fix, a feature — you do NOT write it yourself. You create a Paperclip ticket and route it to a lane; see the paperclip-api skill for how. Writing the code, creating project files, or uploading a build artifact into the chat is a ROUTING FAILURE, no matter how small the task looks or how quickly you could just do it. Deliverables reach the user as a Paperclip ticket plus the link the assigned agent posts back. Understanding, research, planning, summarising and answering questions ARE yours — implementation is not."
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

# Delegation clause migration for existing volumes (see the frontdoor
# entrypoint for why this clause is in the prompt and not in the skill).
# This home historically had NO system_prompt, so insert rather than append.
if [ -f "$HH/config.yaml" ] && ! grep -q "chief of staff" "$HH/config.yaml"; then
    python3 - "$HH/config.yaml" <<'PYEOF'
import sys, re
path = sys.argv[1]
src = open(path).read()
line = '  system_prompt: "You are OPC\'s chief of staff, not an implementer. When the user asks for something to be BUILT or CHANGED in code — an app, a script, a prototype, a bug fix, a feature — you do NOT write it yourself. You create a Paperclip ticket and route it to a lane; see the paperclip-api skill for how. Writing the code, creating project files, or uploading a build artifact into the chat is a ROUTING FAILURE, no matter how small the task looks or how quickly you could just do it. Deliverables reach the user as a Paperclip ticket plus the link the assigned agent posts back. Understanding, research, planning, summarising and answering questions ARE yours — implementation is not."' + "\n"
if re.search(r'^  system_prompt:', src, re.M):
    src = re.sub(r'(^  system_prompt: ".*?)"$',
                 lambda m: m.group(1) + " " + "You are OPC's chief of staff, not an implementer. When the user asks for something to be BUILT or CHANGED in code — an app, a script, a prototype, a bug fix, a feature — you do NOT write it yourself. You create a Paperclip ticket and route it to a lane; see the paperclip-api skill for how. Writing the code, creating project files, or uploading a build artifact into the chat is a ROUTING FAILURE, no matter how small the task looks or how quickly you could just do it. Deliverables reach the user as a Paperclip ticket plus the link the assigned agent posts back. Understanding, research, planning, summarising and answering questions ARE yours — implementation is not." + '"', src, count=1, flags=re.M | re.S)
else:
    src = re.sub(r'^(agent:\n(?:  [^\n]*\n|    [^\n]*\n)*)', lambda m: m.group(1) + line, src, count=1, flags=re.M)
open(path, "w").write(src)
PYEOF
    echo "[hermes] added delegation clause to $HH/config.yaml"
fi

# Key routing: for provider "custom", Hermes reads OPENAI_API_KEY +
# OPENAI_BASE_URL from the environment (or $HERMES_HOME/.env).
: "${OPENAI_API_KEY:=$OPENCODE_API_KEY}"
: "${OPENAI_BASE_URL:=${OPENCODE_GO_BASE_URL:-https://opencode.ai/zen/go/v1}}"
export OPENAI_API_KEY OPENAI_BASE_URL

# Single-owner home: everything under $HERMES_HOME must belong to the hermes
# runtime uid (10000) — the dashboard/gateway services run as that user, and
# the Buzz front-door agent (same shared frontdoor-hermes volume) runs as it
# too via its setpriv wrapper. A root-owned state.db/-wal is read-only for
# uid 10000 (preflight fails → "TUI session store unavailable" spam) and
# SQLite WAL cannot be shared across two unix users. Root entrypoint seeds
# (config.yaml, plugins, skills) are written before this line, so chown -R
# at boot keeps ownership deterministic even on pre-existing volumes.
chown -R "${HERMES_UID:-10000}:${HERMES_GID:-10000}" "$HH" 2>/dev/null || true

exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"
