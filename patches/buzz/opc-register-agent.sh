#!/bin/sh
# opc-register-agent.sh — self-healing registration for the front-door agent.
#
# After a fresh deploy the relay/community exists but the agent is not yet in
# any channel (channels are created by the desktop on first join) and has no
# kind:0 profile, so it shows as a raw hex pubkey. This loop fixes both:
#   (1) publishes the agent's kind:0 profile (name: hermes) — idempotent,
#   (2) joins the agent to every channel it can see (kind:9000 as relay owner).
# buzz-acp picks up each membership via its subscription and goes online in
# the channel automatically. Runs alongside buzz-acp in the frontdoor pod.
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

# 2) Profile (kind:0) — read-merge-write republish. Published once; only
#    retried on failure (republishing every loop tick would spam the relay).
profile_ok=0
publish_profile() {
    if buzz --relay "$RELAY_API" --private-key "$AGENT_NSEC" users set-profile \
        --name hermes --about 'OPC front-door agent (hermes + opencode go)' \
        >/dev/null 2>&1; then
        profile_ok=1
        log "profile published"
    else
        log "profile publish failed — will retry"
    fi
}
publish_profile

while true; do
    if [ "$profile_ok" -ne 1 ]; then
        publish_profile
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
