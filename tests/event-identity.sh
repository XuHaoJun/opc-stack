#!/usr/bin/env bash
# Live gate for the Paperclip notifier identity.
#
# What must hold: the identity exists with its own key (mode 600), it presents a
# display name, it is NOT registered as an interactive agent (no channel
# membership, so buzz-acp can never discover or drive it, and no kind:10100
# publication), and the front door knows which authors are agents (the
# deterministic loop breaker's seed list).
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL  $*" >&2; exit 1; }
pass() { echo "PASS  $*"; }

for file in paperclip.nsec paperclip.pub opc-control.key; do
    docker compose exec -T buzz test -s "/keys/$file" || fail "missing /keys/$file (recreate buzz-keys)"
done
pass "keys exist"

for file in paperclip.nsec opc-control.key; do
    mode="$(docker compose exec -T buzz stat -c %a "/keys/$file" | tr -d '[:space:]')"
    [ "$mode" = "600" ] || fail "/keys/$file mode is $mode, expected 600"
done
pass "keys are 600"

# The relay's community is bound to the host in BUZZ_RELAY_URL; `localhost`
# resolves to a host with no community ("404 no community is configured"), so
# every query must use the same address the agent does.
RELAY="$(docker compose exec -T frontdoor printenv BUZZ_RELAY_URL | tr -d '[:space:]')"
RELAY_HTTP="http://$(printf '%s' "$RELAY" | sed 's#^wss\?://##')"

PUB="$(docker compose exec -T buzz cat /keys/paperclip.pub | tr -d '[:space:]')"
[ "${#PUB}" -eq 64 ] || fail "paperclip.pub is not a 64-char hex pubkey"

# opc-register-agent publishes the profile on a retry loop; give it 60s.
NAME=""
for _ in $(seq 1 12); do
    # BUZZ_AUTH_TAG is bound to the front door's key; presenting it with the
    # notifier's key makes every command fail verification.
    NAME="$(docker compose exec -T frontdoor sh -c "BUZZ_AUTH_TAG= buzz --relay $RELAY_HTTP --private-key \"\$(cat /keys/paperclip.nsec)\" users get --pubkey $PUB" 2>/dev/null \
        | jq -r 'if type=="array" then (.[0].display_name // .[0].name // empty) else (.display_name // .name // empty) end' 2>/dev/null || true)"
    [ "$NAME" = "paperclip" ] && break
    sleep 5
done
[ "$NAME" = "paperclip" ] || fail "paperclip kind:0 name is '$NAME', expected 'paperclip'"
pass "kind:0 profile published as 'paperclip'"

# Creating the control channel makes the creator a member (relay side effect),
# so the assertion is: no membership OTHER than that channel. Membership is what
# buzz-acp uses to discover an agent; a single control channel is inert.
CTL="$(docker compose exec -T event-bridge python3 -c "
from opc_bridge import config, store
print(store.Store(config.load().db_path).get_meta('control_channel') or '')
")"
MEMBERSHIP_JSON="$(docker compose exec -T frontdoor sh -c "BUZZ_AUTH_TAG= buzz --relay $RELAY_HTTP --private-key \"\$(cat /keys/paperclip.nsec)\" channels list --member" 2>/dev/null)" \
    || fail "paperclip membership query failed — the gate cannot verify identity separation"
jq -e 'type == "array"' <<<"$MEMBERSHIP_JSON" >/dev/null 2>&1 \
    || fail "paperclip membership query returned non-JSON: $MEMBERSHIP_JSON"
JOINED_OTHER="$(jq -c --arg ctl "$CTL" '[.[] | select(.channel_id != $ctl) | .channel_id]' <<<"$MEMBERSHIP_JSON")"
[ "$JOINED_OTHER" = "[]" ] || fail "paperclip joined non-control channel(s): $JOINED_OTHER (it must stay undiscoverable as an agent)"
pass "paperclip is not a channel member (invisible to buzz-acp)"

grep -q 'paperclip|paperclip|Paperclip work events and notifications|profile' patches/buzz/opc-register-agent.sh \
    || fail "register-agent no longer marks paperclip as profile-only"
pass "registration is profile-only (no kind:10100, no join)"

# `docker compose exec` does NOT inherit variables the entrypoint exported at
# boot (AGENTS.md, "known pits"), so read what the process actually logged.
AUTHORS="$(docker compose logs frontdoor 2>&1 | grep "agent-author gate seeded" | tail -1 | sed 's/.*seeded (\([^)]*\)).*/\1/' | tr -d '[:space:]')"
[ -n "$AUTHORS" ] || fail "frontdoor never logged the agent-author seed (entrypoint did not run?)"
SCIENTIST="$(docker compose exec -T buzz cat /keys/scientist.pub | tr -d '[:space:]')"
AGENT_PUB="$(docker compose exec -T buzz cat /keys/agent.pub | tr -d '[:space:]')"
case ",$AUTHORS," in
    *",$SCIENTIST,"*) ;;
    *) fail "agent-author seed does not include scientist.pub ($SCIENTIST): '$AUTHORS'" ;;
esac
case ",$AUTHORS," in
    *",$AGENT_PUB,"*) fail "agent-author seed must not include the front door's own key" ;;
esac
case ",$AUTHORS," in
    *",$PUB,"*) fail "agent-author seed must not include the notifier key" ;;
esac
pass "front door seeds the agent-author list (scientist only)"
