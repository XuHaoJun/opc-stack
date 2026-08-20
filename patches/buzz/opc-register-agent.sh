#!/bin/sh
# opc-register-agent.sh — self-healing registration for every Buzz identity
# this deployment maintains (front door + expert agents).
#
# After a fresh deploy the relay/community exists but an identity is not yet
# in any channel (channels are created by the desktop on first join) and has
# no kind:0 profile, so it shows as a raw hex pubkey. This loop fixes all
# three discovery surfaces per identity, each with independent retry state:
#   (1) publishes the identity's kind:0 profile — idempotent,
#   (2) publishes the identity's kind:10100 agent-directory profile (policy:
#       anyone) so the desktop can discover it,
#   (3) joins the identity to every channel it can see (kind:9000 as relay owner).
# buzz-acp picks up the front door's membership via its subscription and goes
# online in the channel automatically; expert agents post through the hermes
# gateway's own buzz wrapper. Runs alongside buzz-acp in the frontdoor pod.
set -eu

BUZZ_KEYS_DIR="${BUZZ_KEYS_DIR:-/keys}"
RELAY="${BUZZ_RELAY_URL:-ws://localhost:3000}"
RELAY_API="http://$(printf '%s' "$RELAY" | sed 's#^wss\?://##')"
RELAY_NSEC="$(cat "$BUZZ_KEYS_DIR/relay.nsec")"

# The ambient BUZZ_AUTH_TAG (owner attestation) is cryptographically bound to
# ONE specific pubkey — the front-door agent's, minted by the owner-bootstrap
# flow (docs/superpowers/specs/2026-08-19-buzz-agent-owner-bootstrap-design.md).
# The buzz CLI verifies it locally against whatever --private-key it is given
# before doing anything else, and rejects EVERY command (not just kind:0/10100
# — plain reads like `channels list` too) the instant the signing pubkey
# doesn't match: `{"error":"auth_error", "message":"...signature failed
# verification"}`. Measured directly: this fires for the scientist identity
# and even for relay.nsec, so the tag must never be passed to any call signed
# by something other than the exact identity it was minted for. Save it once
# and unset the ambient copy; only the agent branch below re-supplies it.
OWNER_AUTH_TAG="${BUZZ_AUTH_TAG:-}"
unset BUZZ_AUTH_TAG || true

# Identities this loop maintains: <key-basename>|<kind:0 name>|<about>.
# The front door is the chief of staff; the rest are expert agents that live
# as hermes profiles in the gateway container and post their own findings.
AGENTS="agent|hermes|OPC front-door agent (hermes + opencode go)
scientist|scientist|OPC research agent (exploratory experiments)"

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

# 2) Attested discovery surfaces. The buzz CLI injects whatever auth tag it
#    is given into both signed events — never built here — and the loop below
#    supplies OWNER_AUTH_TAG only for the "agent" identity it was minted for.
#    Per-identity retry state lives in files rather than shell variables,
#    because the set is now a loop: /tmp/reg-<who>-<what> exists once that
#    surface has been published successfully, so a success is never
#    republished (which would spam the relay) and only failures retry.
#    Lifetime note: /tmp is in the container filesystem, so these markers
#    survive `docker restart` but NOT a container recreate (up --build,
#    compose changes, down/up). Consequence: if the relay loses an identity's
#    kind:0 / kind:10100 / channel membership while the container keeps
#    running, this loop believes it already published and those surfaces stay
#    gone until the container is recreated (or the marker deleted by hand).
publish_surfaces() { # <who> <name> <about> <nsec> <auth-tag>
    _who="$1"; _name="$2"; _about="$3"; _nsec="$4"; _tag="${5:-}"
    if [ ! -f "/tmp/reg-$_who-meta" ]; then
        if BUZZ_AUTH_TAG="$_tag" buzz --relay "$RELAY_API" --private-key "$_nsec" users set-profile \
            --name "$_name" --about "$_about" >/dev/null 2>&1; then
            : > "/tmp/reg-$_who-meta"
            log "$_who: kind 0 profile published"
        else
            log "$_who: kind 0 profile publish failed — will retry"
        fi
    fi
    if [ ! -f "/tmp/reg-$_who-dir" ]; then
        if BUZZ_AUTH_TAG="$_tag" buzz --relay "$RELAY_API" --private-key "$_nsec" \
            channels set-add-policy --policy anyone >/dev/null 2>&1; then
            : > "/tmp/reg-$_who-dir"
            log "$_who: kind 10100 agent directory profile published"
        else
            log "$_who: kind 10100 agent directory publish failed — will retry"
        fi
    fi
}

while true; do
    printf '%s\n' "$AGENTS" | while IFS='|' read -r who name about; do
        [ -n "$who" ] || continue
        nsec_file="$BUZZ_KEYS_DIR/$who.nsec"
        pub_file="$BUZZ_KEYS_DIR/$who.pub"
        [ -s "$nsec_file" ] && [ -s "$pub_file" ] || continue
        nsec="$(cat "$nsec_file")"
        pk="$(cat "$pub_file")"
        # Only the identity the owner attestation was minted for may present
        # it — see the note above the OWNER_AUTH_TAG assignment.
        who_tag=""
        [ "$who" = "agent" ] && who_tag="$OWNER_AUTH_TAG"

        publish_surfaces "$who" "$name" "$about" "$nsec" "$who_tag"

        # Join every visible channel this identity is not already in.
        all_ids="$(BUZZ_AUTH_TAG="$who_tag" buzz --relay "$RELAY_API" --private-key "$nsec" channels list 2>/dev/null | jq -r '.[].channel_id' 2>/dev/null || true)"
        my_ids="$(BUZZ_AUTH_TAG="$who_tag" buzz --relay "$RELAY_API" --private-key "$nsec" channels list --member 2>/dev/null | jq -r '.[].channel_id' 2>/dev/null || true)"
        [ -n "$all_ids" ] || continue
        printf '%s\n' "$all_ids" > "/tmp/reg-all-$who"
        : > "/tmp/reg-my-$who"
        [ -n "$my_ids" ] && printf '%s\n' "$my_ids" > "/tmp/reg-my-$who"
        missing="$(grep -vxFf "/tmp/reg-my-$who" "/tmp/reg-all-$who" || true)"
        [ -n "$missing" ] || continue
        for cid in $missing; do
            # Signed by the relay owner, whose pubkey never matches the
            # front-door's attestation — never present the tag here either.
            if BUZZ_AUTH_TAG="" buzz --relay "$RELAY_API" --private-key "$RELAY_NSEC" channels add-member \
                --channel "$cid" --pubkey "$pk" --role bot >/dev/null 2>&1; then
                log "$who: joined channel $cid"
            else
                log "$who: add-member failed for $cid (restricted/transient) — will retry"
            fi
        done
    done
    sleep 30
done
