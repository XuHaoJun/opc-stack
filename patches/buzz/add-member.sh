#!/bin/sh
# One-shot bootstrap: waits for the relay, then grants the front-door agent
# pubkey relay membership (idempotent). Runs with the owner identity.
set -eu

export BUZZ_RELAY_PRIVATE_KEY="$(cat "${KEYS_DIR:-/keys}/relay.nsec")"
export RELAY_OWNER_PUBKEY="$(cat "${KEYS_DIR:-/keys}/relay.pub")"
# buzz-admin reads RELAY_URL (not BUZZ_RELAY_URL) for tenant resolution.
_canonical="${BUZZ_RELAY_URL:-ws://localhost:3000}"
export RELAY_URL="${RELAY_ADMIN_URL:-http://$(printf '%s' "$_canonical" | sed 's#^wss\?://##')}"
export BUZZ_RELAY_URL="$_canonical"

ready=""
for _ in $(seq 1 120); do
    if curl -fsS "http://buzz:8080/_readiness" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 2
done
[ -n "$ready" ] || { echo "[bootstrap] relay never became ready" >&2; exit 1; }

# Every agent identity that posts to the relay needs membership.
#
# Adding the next expert is FOUR edits, not one — the identity list is
# duplicated across four files and nothing checks them against each other:
#   1. patches/buzz/generate-keys.sh        `gen <expert>`  (mints the keypair)
#   2. patches/buzz/add-member.sh           this loop       (relay membership)
#   3. patches/buzz/opc-register-agent.sh   the AGENTS list (kind:0 + kind:10100
#                                                            + channel joins)
#   4. patches/hermes/hermes-entrypoint.sh  `opc_seed_expert_profile agt-<expert>`
#                                                           (mirrors the key into
#                                                            the profile home)
# Miss THIS entry specifically and the failure is invisible: the key is
# generated, mirrored into the profile, and the CLI happily signs with it —
# but the relay drops every event from a non-member, so the expert posts
# nothing and no gate in this repo catches it.
for _who in agent scientist; do
    _pub="${KEYS_DIR:-/keys}/$_who.pub"
    [ -s "$_pub" ] || { echo "[bootstrap] no $_who.pub — skipping"; continue; }
    /usr/local/bin/buzz-admin add-member --pubkey "$(cat "$_pub")" --role member
    echo "[bootstrap] $_who is a relay member"
done
