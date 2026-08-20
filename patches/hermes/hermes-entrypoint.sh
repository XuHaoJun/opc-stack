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


# Agent identity: sync SOUL.md from the image on every boot.
#
# This is where the "you are not the implementer" rule lives, and it has to be
# here rather than in config.yaml's agent.system_prompt: that key is resolved
# by `class HermesCLI` in cli.py, so it applies to `hermes chat` and NOT to
# `hermes acp` — the lane this front door actually runs. AIAgent builds SOUL.md
# into its own prompt (agent/system_prompt.py -> load_soul_md, scoped to the
# agent's own home), so SOUL.md holds in every lane.
#
# Overwritten every boot on purpose: the image is the source of truth, the same
# way skills are. config.yaml is NOT a safe place for a rule that must hold —
# hermes migrates that file and this volume arrived at _config_version 37 with
# its seeded system_prompt silently gone.
if [ -f /opt/hermes/SOUL.md ]; then
    mkdir -p "$HH"
    cp /opt/hermes/SOUL.md "$HH/SOUL.md"
    echo "[hermes] synced SOUL.md (agent identity + delegation rule)"
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
  api_key: \${OPENAI_API_KEY}
  base_url: ${OPENAI_BASE_URL:-https://opencode.ai/zen/go/v1}
  default: ${OPENAI_MODEL:-deepseek-v4-flash}
YAML
    echo "[hermes] seeded $HH/config.yaml (kanban disabled; memory=tencentdb; model=${OPENAI_MODEL:-deepseek-v4-flash})"
fi

# Refresh seeded model lines on existing volumes that still carry the legacy
# hardcoded default (config.yaml is dashboard-editable afterwards; only the
# exact legacy values are rewritten, not user edits).
if [ -f "$HH/config.yaml" ]; then
    sed -i "s|^  default: deepseek-v4-pro$|  default: ${OPENAI_MODEL:-deepseek-v4-flash}|; s|^  base_url: https://opencode\\.ai/zen/go/v1$|  base_url: ${OPENAI_BASE_URL:-https://opencode.ai/zen/go/v1}|" "$HH/config.yaml"
    # Existing editable configs may predate the explicit custom-provider key
    # route. Insert only when the model block has no api_key; operator-set
    # credentials are left untouched.
    python3 - "$HH/config.yaml" <<'PYEOF'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    lines = handle.readlines()
start = next((i for i, line in enumerate(lines) if re.match(r"^model:\s*$", line)), None)
if start is None:
    raise SystemExit(0)
end = next(
    (i for i in range(start + 1, len(lines)) if lines[i].strip() and not lines[i].startswith((" ", "\t"))),
    len(lines),
)
block = lines[start:end]
if any(re.match(r"^  api_key\s*:", line) for line in block):
    raise SystemExit(0)
if not any(re.match(r"^  provider:\s*custom\s*$", line.rstrip("\n")) for line in block):
    raise SystemExit(0)
provider = next(i for i in range(start + 1, end) if re.match(r"^  provider:\s*custom\s*$", lines[i].rstrip("\n")))
lines.insert(provider + 1, "  api_key: ${OPENAI_API_KEY}\n")
with open(path, "w", encoding="utf-8") as handle:
    handle.writelines(lines)
print("[hermes] added model.api_key env reference to existing config")
PYEOF
    # Pre-s12 configs (no _config_version) trip hermes's "predates version
    # 12" migration refusal on every boot; stamp the current version once.
    if ! grep -q "^_config_version:" "$HH/config.yaml"; then
        sed -i "1i _config_version: 34" "$HH/config.yaml"
        echo "[hermes] stamped _config_version: 34 onto existing $HH/config.yaml"
    fi
fi


# Key routing: for provider "custom", Hermes reads OPENAI_API_KEY +
# OPENAI_BASE_URL from the environment (or $HERMES_HOME/.env).
: "${OPENAI_API_KEY:=}"
: "${OPENAI_BASE_URL:=https://opencode.ai/zen/go/v1}"
export OPENAI_API_KEY OPENAI_BASE_URL

# ── Expert agent profiles ──────────────────────────────────────────────
# Each expert is a named hermes profile under $HERMES_HOME/profiles/, served
# by this one gateway process (GATEWAY_MULTIPLEX_PROFILES=1). The directory
# lives on the hermes-profiles volume, which the dashboard also mounts — that
# is what puts the expert in the dashboard's global profile switcher
# (list_profiles() enumerates $HERMES_HOME/profiles).
#
# Idempotent: config.yaml and .env are seeded only when absent (both are
# dashboard-editable afterwards), while SOUL.md and skills are overwritten
# every boot from the image — same split, and same reasoning, as the default
# profile above.
opc_seed_expert_profile() { # <profile-name> <api-key-value>
    _p="$1"
    _key="$2"
    _ph="$HH/profiles/$_p"

    mkdir -p "$_ph/memories" "$_ph/sessions" "$_ph/skills" "$_ph/logs" \
             "$_ph/plans" "$_ph/workspace" "$_ph/cron" "$_ph/home" "$_ph/plugins"

    if [ -z "$_key" ]; then
        echo "[hermes] WARNING profile $_p has no API key — the gateway will 401 every request for it" >&2
    fi

    # Per-profile secrets. Under multiplex the secret scope is authoritative
    # and does NOT fall back to os.environ (agent/secret_scope.py:137-152),
    # precisely so one profile cannot read another's credentials — so the
    # provider key has to be repeated here, it is not inherited.
    if [ ! -f "$_ph/.env" ]; then
        cat > "$_ph/.env" <<ENVEOF
API_SERVER_KEY=$_key
OPENAI_API_KEY=${OPENAI_API_KEY:-}
OPENAI_BASE_URL=${OPENAI_BASE_URL:-https://opencode.ai/zen/go/v1}
ENVEOF
        chmod 600 "$_ph/.env"
        echo "[hermes] seeded $_ph/.env"
    else
        # The API key is operator-rotatable via .env; keep it in sync without
        # touching anything else the dashboard may have written.
        if [ -n "$_key" ] && ! grep -qxF "API_SERVER_KEY=$_key" "$_ph/.env"; then
            sed -i "/^API_SERVER_KEY=/d" "$_ph/.env"
            printf 'API_SERVER_KEY=%s\n' "$_key" >> "$_ph/.env"
            echo "[hermes] refreshed API_SERVER_KEY in $_ph/.env"
        fi
    fi

    if [ ! -f "$_ph/config.yaml" ]; then
        cat > "$_ph/config.yaml" <<YAML
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
  api_key: \${OPENAI_API_KEY}
  base_url: ${OPENAI_BASE_URL:-https://opencode.ai/zen/go/v1}
  default: ${OPENAI_MODEL:-deepseek-v4-flash}
YAML
        echo "[hermes] seeded $_ph/config.yaml"
    fi

    # Memory provider: same image copy the default profile gets. The plugin
    # scopes writes by agent_identity (= the profile name) because
    # MEMORY_TENCENTDB_AGENT_ID is process-wide and must stay UNSET on this
    # container — that is why the profile is named agt-scientist and not
    # scientist (the panel parses chat_memory-{team}-{agent} with
    # lastIndexOf('-agt')).
    if [ -d "/opt/hermes/memory_tencentdb" ]; then
        rm -rf "$_ph/plugins/memory_tencentdb"
        cp -r /opt/hermes/memory_tencentdb "$_ph/plugins/memory_tencentdb"
    fi

    # paperclip-api skill: the expert files its own findings as backlog issues.
    if [ -d "/opt/hermes/skills/paperclip-api" ]; then
        rm -rf "$_ph/skills/paperclip-api"
        cp -r /opt/hermes/skills/paperclip-api "$_ph/skills/paperclip-api"
    fi

    echo "[hermes] expert profile ready: $_p"
}

opc_seed_expert_profile agt-scientist "${HERMES_SCIENTIST_API_KEY:-}"

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
