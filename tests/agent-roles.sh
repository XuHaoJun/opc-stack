#!/usr/bin/env bash
# Paperclip coding-agent identity and managed-prompt gate.
# Run from the repo root against a live stack after paperclip-bootstrap.
set -uo pipefail
cd "$(dirname "$0")/.."
. "$(dirname "$0")/../scripts/load-env.sh"; opc_load_env ./.env

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}

API="http://127.0.0.1:${PAPERCLIP_PORT:-3100}/api"
PC_KEY="$(docker compose exec -T hermes cat /keys/paperclip-api.key 2>/dev/null | tr -d '\r\n')"
api_get() { curl -fsS -H "Authorization: Bearer $PC_KEY" "$API$1"; }
case "${PAPERCLIP_EXECUTOR_AGENT_NAME:-}" in
    ""|"OMP Engineer")
        expected_executor_name="Fullstack Engineer"
        canonical_migration=1
        ;;
    *)
        expected_executor_name="$PAPERCLIP_EXECUTOR_AGENT_NAME"
        canonical_migration=0
        ;;
esac


company_id="$(api_get /companies | jq -r '.[0].id // empty' 2>/dev/null)"
agents_json="$(api_get "/companies/$company_id/agents" 2>/dev/null || printf '[]')"
executor_id="$(printf '%s' "$agents_json" | jq -r --arg n "$expected_executor_name" '[.[] | select(.name == $n)] | if length == 1 then .[0].id else empty end')"
prototyper_id="$(printf '%s' "$agents_json" | jq -r '[.[] | select(.name == "Prototyper")] | if length == 1 then .[0].id else empty end')"

check "exactly one expected executor exists" test -n "$executor_id"
if [ "$canonical_migration" -eq 1 ]; then
    check "legacy OMP Engineer no longer exists" sh -c "printf '%s' \"\$1\" | jq -e '[.[] | select(.name == \"OMP Engineer\")] | length == 0' >/dev/null" sh "$agents_json"
fi
check "executor has the engineer role" sh -c "printf '%s' \"\$1\" | jq -e --arg id \"\$2\" '.[] | select(.id == \$id) | .role == \"engineer\"' >/dev/null" sh "$agents_json" "$executor_id"
check "exactly one Prototyper exists" test -n "$prototyper_id"

check_prompt() { # label agent-id desired-file
    local label="$1" id="$2" desired="$3" got want
    if [ -z "$id" ] || [ ! -f "$desired" ]; then
        fail "$label"
        return
    fi
    got="$(api_get "/agents/$id/instructions-bundle/file?path=AGENTS.md" 2>/dev/null | jq -r '.content // empty')"
    want="$(cat "$desired")"
    if [ -n "$got" ] && [ "$got" = "$want" ]; then pass "$label"; else fail "$label"; fi
}

check_prompt "Fullstack prompt matches bootstrap source" "$executor_id" patches/paperclip/agent-prompts/fullstack-engineer.md
check_prompt "Prototyper prompt matches bootstrap source" "$prototyper_id" patches/paperclip/agent-prompts/prototyper.md
check "Fullstack prompt stays concise" sh -c 'test "$(wc -w < "$1")" -le 180' sh patches/paperclip/agent-prompts/fullstack-engineer.md
check "Prototyper prompt stays concise" sh -c 'test "$(wc -w < "$1")" -le 140' sh patches/paperclip/agent-prompts/prototyper.md

printf '\nresult: %d pass, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
