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
# Additional agents to register: `id:name` entries separated by a COMMA (or a
# newline) — NOT whitespace. Names are human-readable and routinely contain
# spaces (the default agent above is literally "Hermes Front Door"), so
# whitespace-splitting `agt-market:Market Research` yields two entries,
# `agt-market:Market` and `Research` — and the second registers an agent whose
# id is `Research`, with no `agt` prefix at all. Every id MUST start with
# `agt`: the Memory Hub panel parses chat_memory-{team}-{agent} asset ids with
# lastIndexOf('-agt'), and an id without that prefix leaves the panel silently
# empty. That invariant is enforced in ensure_agent() below rather than left
# to this comment.
EXTRA_AGENTS="${TENCENTDB_EXTRA_AGENTS:-agt-scientist:Scientist}"

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

# 3. Agents: get → create. createAgent mints the chat_memory asset + fixed
#    binding automatically, so the panel's Chat_Memory page renders the data.
ensure_agent() { # <agent_id> <agent_name>
  _aid="$1"
  _aname="$2"
  case "$_aid" in
    agt*) ;;
    *)
      echo "[tencentdb-provision] FAILED: agent id '${_aid}' does not start with 'agt' — the Memory Hub panel parses chat_memory-{team}-{agent} with lastIndexOf('-agt') and would render nothing for it; refusing to register it"
      exit 1 ;;
  esac
  if [ -z "$_aname" ]; then
    echo "[tencentdb-provision] FAILED: agent '${_aid}' has an empty name"
    exit 1
  fi
  CODE="$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST "$GATEWAY/v3/meta/agent/get" \
    -H 'Content-Type: application/json' -H 'x-tdai-service-id: default' \
    -H "Authorization: Bearer ${API_KEY}" -H "x-tdai-user-key: ${USER_KEY}" \
    -d "{\"agent_id\":\"${_aid}\"}")"
  if [ "$CODE" = "200" ]; then
    echo "[tencentdb-provision] agent '${_aid}' already exists"
  else
    RES="$(meta /v3/meta/agent/create "{\"team_id\":\"${TEAM_ID}\",\"agent_id\":\"${_aid}\",\"owner_user_id\":\"${USER_ID}\",\"name\":\"${_aname}\"}")"
    echo "[tencentdb-provision] agent '${_aid}' created: $(printf '%s' "$RES" | head -c 200)"
  fi
}

ensure_agent "$AGENT_ID" "$AGENT_NAME"

# Split on comma/newline only (see EXTRA_AGENTS above), with globbing off:
# unquoted word-splitting also pathname-expands, so an entry containing `*`
# or `?` would silently become whatever happens to match in the CWD.
_old_ifs="$IFS"
set -f
IFS=',
'
for _entry in $EXTRA_AGENTS; do
  set +f
  IFS="$_old_ifs"
  # Trim surrounding whitespace so `a:A, b:B` works as it reads.
  _entry="$(printf '%s' "$_entry" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [ -n "$_entry" ]; then
    case "$_entry" in
      *:*) ;;
      *)
        echo "[tencentdb-provision] FAILED: TENCENTDB_EXTRA_AGENTS entry '${_entry}' has no ':' — expected comma-separated 'agt-<id>:<Display Name>' pairs"
        exit 1 ;;
    esac
    ensure_agent "$(printf '%s' "${_entry%%:*}" | sed -e 's/[[:space:]]*$//')" \
                 "$(printf '%s' "${_entry#*:}" | sed -e 's/^[[:space:]]*//')"
  fi
  set -f
  IFS=',
'
done
set +f
IFS="$_old_ifs"

echo "[tencentdb-provision] done"
