#!/bin/sh
# OPC TencentDB meta-plane provisioning one-shot.
#
# Ensures the kernel's meta registry (teams / agents / chat_memory assets —
# what the Memory Hub panel at 8125 renders) contains the exact tenancy ids
# the hermes memory_tencentdb plugin writes to the data plane:
#   team  = $TENCENTDB_TEAM_ID   (default "opc")
#   agent = $TENCENTDB_AGENT_ID  (default "agt-hermes-front-door"; must start
#                                 with "agt" — the Memory Hub panel parses
#                                 chat_memory-{team}-{agent} asset ids at the
#                                 last "-agt" boundary).
#
# Without this, the panel shows "No Team Available" even though L0/L1/L2/L3
# data is accumulating: /v3/conversation/add's chat_memory auto-registration
# (ensureChatMemoryAsset) fails until the agent exists in meta.
#
# Idempotent: get-before-create; safe to run on every boot.
set -eu

GATEWAY="${TENCENTDB_GATEWAY_URL:-http://tencentdb-core:8420}"
API_KEY="${TENCENTDB_GATEWAY_API_KEY:-}"
USER_KEY="${TENCENTDB_ADMIN_USER_KEY:?set in .env}"
TEAM_ID="${TENCENTDB_TEAM_ID:-opc}"
TEAM_NAME="${TENCENTDB_TEAM_NAME:-OPC}"
AGENT_ID="${TENCENTDB_AGENT_ID:-agt-hermes-front-door}"
AGENT_NAME="${TENCENTDB_AGENT_NAME:-Hermes Front Door}"

meta() { # <path> <json-body> → envelope via stdout
  curl -fsS -m 30 -X POST "$GATEWAY$1" \
    -H 'Content-Type: application/json' \
    -H 'x-tdai-service-id: default' \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "x-tdai-user-key: ${USER_KEY}" \
    -d "$2"
}

# Extract a dotted-path field from a JSON document on stdin (node ships in the image).

echo "[tencentdb-provision] gateway=${GATEWAY} team=${TEAM_ID} agent=${AGENT_ID}"

# 1. Resolve the admin user_id from the admin user_key.
VERIFY="$(meta /v3/meta/auth/verify "{\"user_key\":\"${USER_KEY}\"}")"
USER_ID="$(printf '%s' "$VERIFY" | node -e '
  let s = "";
  process.stdin.on("data", d => s += d).on("end", () => {
    const user = JSON.parse(s).data && JSON.parse(s).data.user;
    process.stdout.write(user && user.user_id ? user.user_id : "");
  });
')"
if [ -z "$USER_ID" ]; then
  echo "[tencentdb-provision] FAILED: could not resolve user_id from admin user_key"
  exit 1
fi
echo "[tencentdb-provision] admin user_id=${USER_ID}"

# Expose the admin user_id to the agent stack via the shared keys volume:
# the frontdoor/hermes entrypoints export it as MEMORY_TENCENTDB_USER_ID so
# the memory plugin writes L0/L1 under the SAME user_id the Memory Hub panel
# queries with (asset.owner_user_id). Without this, data lands under
# user_id="default" and the panel's layer views stay empty (L0/L1 are
# user-scoped in the data plane).
mkdir -p /keys
printf '%s' "$USER_ID" > /keys/tencentdb-admin-user-id
echo "[tencentdb-provision] wrote /keys/tencentdb-admin-user-id"

# 2. Team: get → create (explicit team_id; schema patched by the OPC overlay).
CODE="$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST "$GATEWAY/v3/meta/team/get" \
  -H 'Content-Type: application/json' -H 'x-tdai-service-id: default' \
  -H "Authorization: Bearer ${API_KEY}" -H "x-tdai-user-key: ${USER_KEY}" \
  -d "{\"team_id\":\"${TEAM_ID}\"}")"
if [ "$CODE" = "200" ]; then
  echo "[tencentdb-provision] team '${TEAM_ID}' already exists"
else
  RES="$(meta /v3/meta/team/create "{\"team_id\":\"${TEAM_ID}\",\"name\":\"${TEAM_NAME}\",\"owner_user_id\":\"${USER_ID}\"}")"
  echo "[tencentdb-provision] team '${TEAM_ID}' created: $(printf '%s' "$RES" | head -c 200)"
fi

# 3. Agent: get → create. createAgent mints the chat_memory asset + fixed
#    binding automatically, so the panel's Chat_Memory page renders the data.
CODE="$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST "$GATEWAY/v3/meta/agent/get" \
  -H 'Content-Type: application/json' -H 'x-tdai-service-id: default' \
  -H "Authorization: Bearer ${API_KEY}" -H "x-tdai-user-key: ${USER_KEY}" \
  -d "{\"agent_id\":\"${AGENT_ID}\"}")"
if [ "$CODE" = "200" ]; then
  echo "[tencentdb-provision] agent '${AGENT_ID}' already exists"
else
  RES="$(meta /v3/meta/agent/create "{\"team_id\":\"${TEAM_ID}\",\"agent_id\":\"${AGENT_ID}\",\"owner_user_id\":\"${USER_ID}\",\"name\":\"${AGENT_NAME}\"}")"
  echo "[tencentdb-provision] agent '${AGENT_ID}' created: $(printf '%s' "$RES" | head -c 200)"
fi

echo "[tencentdb-provision] done"
