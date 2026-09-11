#!/usr/bin/env bash
# Phase 0 measurement driver for the memory hardening spec
# (docs/superpowers/specs/2026-09-10-agent-memory-scoping-design.md, 7.0).
#
# Runs the L1-quality experiment in TWO ISOLATED test agent scopes. Never reuse a
# single agent_id for both conditions: L0→L1→L2→L3 is stateful, so condition A's
# output becomes condition B's starting state (memories_since_last_persona only
# ever increases — MemoryCore/src/utils/checkpoint.ts:641-642).
set -euo pipefail
cd "$(dirname "$0")/.."
. "$(dirname "$0")/load-env.sh"; opc_load_env ./.env

TEAM="${TENCENTDB_TEAM_ID:-${MEMORY_TENCENTDB_TEAM_ID:-opc}}"
CORE="http://127.0.0.1:8420"
API_KEY="${TENCENTDB_GATEWAY_API_KEY:-}"
USER_KEY="${TENCENTDB_ADMIN_USER_KEY:-}"

api() {
  # $1 = path, $2 = json body
  # Header set mirrors meta() in
  # patches/tencentdb-agent-memory/MemoryCore/opc-tencentdb-provision.sh:
  # the gateway requires x-tdai-service-id (canonical value 'default') and
  # the admin x-tdai-user-key alongside the bearer token.
  # stdin is detached: callers loop over the transcript on stdin while
  # `docker compose exec` would otherwise steal it (only the first turn
  # would land).
  docker compose exec -T tencentdb-core \
    curl -fsS -X POST "http://127.0.0.1:8420$1" \
      -H "Content-Type: application/json" \
      -H "x-tdai-service-id: default" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "x-tdai-user-key: ${USER_KEY}" \
      -d "$2" < /dev/null
}

require_agt() {
  case "$1" in
    agt*) ;;
    *) echo "refusing agent id '$1': must start with 'agt' (the panel parses" >&2
       echo "chat_memory-{team}-{agent} with lastIndexOf('-agt'))" >&2
       exit 2 ;;
  esac
}

admin_user_id() {
  api /v3/meta/auth/verify "{\"user_key\":\"${USER_KEY}\"}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["user"]["user_id"])'
}

cmd="${1:-}"; shift 2>/dev/null || true

case "$cmd" in
  provision)
    agent="${1:?usage: provision <agent_id>}"
    require_agt "$agent"
    owner="$(admin_user_id)"
    api /v3/meta/agent/create "{\"team_id\":\"$TEAM\",\"agent_id\":\"$agent\",\"owner_user_id\":\"$owner\",\"name\":\"$agent\"}"
    echo "provisioned $agent"
    ;;
  replay)
    agent="${1:?usage: replay <agent_id> <transcript>}"
    transcript="${2:?usage: replay <agent_id> <transcript>}"
    require_agt "$agent"
    n=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      n=$((n+1))
      ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      api /v3/conversation/add "$(printf '{"team_id":"%s","agent_id":"%s","user_id":"%s","session_id":"exp-%s","messages":[{"role":"user","content":%s,"timestamp":"%s"}]}' \
        "$TEAM" "$agent" "${MEMORY_TENCENTDB_USER_ID:-default}" "$agent" \
        "$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" "$ts")" >/dev/null
    done < "$transcript"
    echo "replayed $n turns into $agent"
    ;;
  report)
    agent="${1:?usage: report <agent_id>}"
    require_agt "$agent"
    echo "── L1 sample ──"
    api /v3/atomic/search "{\"team_id\":\"$TEAM\",\"agent_id\":\"$agent\",\"user_id\":\"${MEMORY_TENCENTDB_USER_ID:-default}\",\"query\":\"preference\",\"limit\":20}"
    echo
    echo "── L3 persona ──"
    api /v3/core/read "{\"team_id\":\"$TEAM\",\"agent_id\":\"$agent\",\"user_id\":\"${MEMORY_TENCENTDB_USER_ID:-default}\"}"
    echo
    echo "── extraction metrics (grep the core log) ──"
    docker compose logs --no-log-prefix tencentdb-core 2>/dev/null \
      | grep -E "l1_extraction_rate|l1_extracted_count|l0_input_count" | tail -20 || true
    ;;
  *)
    echo "usage: $0 {provision|replay|report} <agent_id> [transcript]" >&2
    exit 64 ;;
esac
