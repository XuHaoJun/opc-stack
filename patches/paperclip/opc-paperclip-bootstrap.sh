#!/bin/sh
# opc-paperclip-bootstrap.sh — one-shot first-boot bootstrap (idempotent).
#
#   1. First admin: sign up (or in) with PAPERCLIP_ADMIN_* creds, then
#      POST /api/bootstrap/claim → that user becomes instance admin.
#   2. Default company (PAPERCLIP_COMPANY_NAME).
#   3. Executor agent (claude_local adapter → `omp acp --yolo`, per AGENTS.md
#      verified handshake config).
#   4. Board API key → /keys/paperclip-api.key (frontdoor/hermes entrypoints
#      export PAPERCLIP_API_KEY from it — no manual .env step).
#
# Re-run reconciles missing pieces only. The key file is the source of truth:
# if it exists, the key is not re-created (the token is only returned once)
# and reconciliation uses it as bearer auth instead of the admin session.
set -eu

API="${PAPERCLIP_API_URL:-http://paperclip:3100}/api"
ORIGIN="${PAPERCLIP_API_URL:-http://paperclip:3100}"
ADMIN_EMAIL="${PAPERCLIP_ADMIN_EMAIL:-admin@opc.local}"
ADMIN_PASSWORD="${PAPERCLIP_ADMIN_PASSWORD:-}"
ADMIN_NAME="${PAPERCLIP_ADMIN_NAME:-Admin}"
COMPANY_NAME="${PAPERCLIP_COMPANY_NAME:-OPC}"
AGENT_NAME="${PAPERCLIP_EXECUTOR_AGENT_NAME:-OMP Engineer}"
KEY_NAME="${PAPERCLIP_KEY_NAME:-frontdoor}"
JAR=/tmp/pc-cookies.txt

[ -n "$ADMIN_PASSWORD" ] || { echo "PAPERCLIP_ADMIN_PASSWORD is required (set in .env)"; exit 1; }

echo "[pc-bootstrap] waiting for paperclip…"
ok=""
for i in $(seq 1 60); do
    if curl -fsS "${API%/api}/api/health" >/dev/null 2>&1; then ok=1; break; fi
    sleep 2
done
[ -n "$ok" ] || { echo "[pc-bootstrap] paperclip not healthy after 120s"; exit 1; }

# ── Auth mode: board key (already bootstrapped) vs admin session (first run) ──
if [ -s /keys/paperclip-api.key ]; then
    AUTH_MODE=key
    KEY="$(cat /keys/paperclip-api.key)"
    echo "[pc-bootstrap] using existing board key for reconciliation"
else
    AUTH_MODE=session
fi

api_get() { # path
    if [ "$AUTH_MODE" = key ]; then
        curl -fsS -H "Authorization: Bearer $KEY" "$API$1" 2>/dev/null || true
    else
        curl -fsS -b "$JAR" "$API$1" 2>/dev/null || true
    fi
}

api_post() { # path body
    if [ "$AUTH_MODE" = key ]; then
        curl -fsS -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
            -H "Origin: $ORIGIN" -X POST "$API$1" -d "$2" 2>/dev/null || true
    else
        curl -fsS -b "$JAR" -H 'Content-Type: application/json' \
            -H "Origin: $ORIGIN" -X POST "$API$1" -d "$2" 2>/dev/null || true
    fi
}

# ── 1. First admin (only when no admin exists yet) ──
if [ "$(curl -fsS "${API%/api}/api/health" | jq -r '.bootstrapStatus // "bootstrap_pending"')" = "ready" ]; then
    echo "[pc-bootstrap] instance already bootstrapped; skipping admin claim"
else
    if ! curl -fsS -c "$JAR" -X POST "$API/auth/sign-in/email" \
            -H 'Content-Type: application/json' \
            -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" >/dev/null 2>&1; then
        echo "[pc-bootstrap] sign-in failed; trying sign-up"
        curl -fsS -c "$JAR" -X POST "$API/auth/sign-up/email" \
            -H 'Content-Type: application/json' \
            -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\",\"name\":\"$ADMIN_NAME\"}" >/dev/null \
            || { echo "[pc-bootstrap] sign-up failed"; exit 1; }
    fi

    code="$(curl -sS -b "$JAR" -o /dev/null -w '%{http_code}' -X POST \
        -H "Origin: $ORIGIN" "$API/bootstrap/claim")"
    case "$code" in
        200|409) echo "[pc-bootstrap] first admin: ok ($code)" ;;
        *) echo "[pc-bootstrap] bootstrap/claim failed: HTTP $code"; exit 1 ;;
    esac
fi

# ── 2. Company ──
company_id="$(api_get "/companies" | jq -r '.[0].id // empty' 2>/dev/null)"
if [ -z "$company_id" ]; then
    company_id="$(api_post "/companies" "{\"name\":\"$COMPANY_NAME\"}" | jq -r '.id // empty')"
    [ -n "$company_id" ] || { echo "[pc-bootstrap] company creation failed (auth?)"; exit 1; }
    echo "[pc-bootstrap] created company: $company_id"
else
    echo "[pc-bootstrap] company exists: $company_id"
fi

# ── 3. Executor agent (claude_local → omp acp) ──
agent_id="$(api_get "/companies/$company_id/agents" | \
    jq -r --arg n "$AGENT_NAME" '.[] | select(.name == $n) | .id' 2>/dev/null | head -1)"
if [ -z "$agent_id" ]; then
    agent_id="$(api_post "/companies/$company_id/agents" \
        "{\"name\":\"$AGENT_NAME\",\"adapterType\":\"claude_local\",\"adapterConfig\":{\"engine\":\"acp\",\"agentCommand\":\"omp acp --yolo\"}}" | jq -r '.id // empty')"
    [ -n "$agent_id" ] || { echo "[pc-bootstrap] agent creation failed (auth?)"; exit 1; }
    echo "[pc-bootstrap] created agent: $agent_id"
else
    echo "[pc-bootstrap] agent exists: $agent_id"
fi

# ── 4. Board API key → /keys/paperclip-api.key ──
if [ ! -s /keys/paperclip-api.key ]; then
    token="$(api_post "/board-api-keys" "{\"name\":\"$KEY_NAME\"}" | jq -r '.token // empty')"
    [ -n "$token" ] || { echo "[pc-bootstrap] board key creation failed (auth?)"; exit 1; }
    umask 077
    mkdir -p /keys
    printf '%s\n' "$token" > /keys/paperclip-api.key
    echo "[pc-bootstrap] wrote /keys/paperclip-api.key"
else
    echo "[pc-bootstrap] key file exists; keeping it"
fi

echo "[pc-bootstrap] done. admin=$ADMIN_EMAIL company=$company_id agent=$AGENT_NAME"
