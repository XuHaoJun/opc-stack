#!/bin/sh
# opc-register-agent.sh — self-healing registration for the front-door agent.
#
# After a fresh deploy the relay/community exists but the agent is not yet in
# any channel (channels are created by the desktop on first join) and has no
# kind:0 profile, so it shows as a raw hex pubkey. This loop fixes all three
# discovery surfaces, each with independent retry state:
#   (1) publishes the agent's kind:0 profile (name: hermes) — idempotent,
#   (2) publishes the agent's kind:10100 agent-directory profile (policy:
#       anyone) so the desktop can discover the agent,
#   (3) joins the agent to every channel it can see (kind:9000 as relay owner).
# buzz-acp picks up each membership via its subscription and goes online in
# the channel automatically. Runs alongside buzz-acp in the frontdoor pod.
# Both events are signed with the ambient BUZZ_AUTH_TAG via the buzz CLI.
set -eu

BUZZ_KEYS_DIR="${BUZZ_KEYS_DIR:-/keys}"
RELAY="${BUZZ_RELAY_URL:-ws://localhost:3000}"
RELAY_API="http://$(printf '%s' "$RELAY" | sed 's#^wss\?://##')"
AGENT_PK="$(cat "$BUZZ_KEYS_DIR/agent.pub")"
RELAY_NSEC="$(cat "$BUZZ_KEYS_DIR/relay.nsec")"
AGENT_NSEC="$(cat "$BUZZ_KEYS_DIR/agent.nsec")"

log() { echo "[register-agent] $*"; }

# 1) Wait for the relay (community ensured) before any API call.
ready=0
i=1
while [ "$i" -le 60 ]; do
    if curl -sf -H 'Accept: application/nostr+json' "$RELAY_API/" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 5
    i=$((i + 1))
done
if [ "$ready" -ne 1 ]; then
    log "relay not reachable after 300s — giving up"
    exit 1
fi
log "relay ready: $RELAY_API"

# 2) Attested discovery surfaces — published once after readiness, then only
#    the failed one is retried each loop (republishing a success every tick
#    would spam the relay). BUZZ_AUTH_TAG is ambient in the frontdoor env;
#    the buzz CLI injects it into both signed events — never built here.
metadata_ok=0
directory_ok=0

publish_metadata() {
    if buzz --relay "$RELAY_API" --private-key "$AGENT_NSEC" users set-profile \
        --name hermes --about 'OPC front-door agent (hermes + opencode go)' \
        >/dev/null 2>&1; then
        metadata_ok=1
        log "kind 0 profile published"
    else
        log "kind 0 profile publish failed — will retry"
    fi
}

publish_directory() {
    if buzz --relay "$RELAY_API" --private-key "$AGENT_NSEC" \
        channels set-add-policy --policy anyone >/dev/null 2>&1; then
        directory_ok=1
        log "kind 10100 agent directory profile published"
    else
        log "kind 10100 agent directory publish failed — will retry"
    fi
}
publish_metadata
publish_directory

while true; do
    if [ "$metadata_ok" -ne 1 ]; then
        publish_metadata
    fi
    if [ "$directory_ok" -ne 1 ]; then
        publish_directory
    fi

    # 3) Join every visible channel the agent is not already a member of.
    all_ids="$(buzz --relay "$RELAY_API" --private-key "$AGENT_NSEC" channels list 2>/dev/null | jq -r '.[].channel_id' 2>/dev/null || true)"
    my_ids="$(buzz --relay "$RELAY_API" --private-key "$AGENT_NSEC" channels list --member 2>/dev/null | jq -r '.[].channel_id' 2>/dev/null || true)"
    if [ -n "$all_ids" ]; then
        printf '%s\n' "$all_ids" > /tmp/reg-all-ids
        : > /tmp/reg-my-ids
        [ -n "$my_ids" ] && printf '%s\n' "$my_ids" > /tmp/reg-my-ids
        missing="$(grep -vxFf /tmp/reg-my-ids /tmp/reg-all-ids || true)"
        if [ -n "$missing" ]; then
            for cid in $missing; do
                if buzz --relay "$RELAY_API" --private-key "$RELAY_NSEC" channels add-member \
                    --channel "$cid" --pubkey "$AGENT_PK" --role bot >/dev/null 2>&1; then
                    log "joined channel $cid"
                else
                    log "add-member failed for $cid (restricted/transient) — will retry"
                fi
            done
        fi
    fi
    sleep 30
done
