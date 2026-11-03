#!/bin/sh
# Generates the relay/owner and front-door agent Nostr keypairs into the
# shared keys volume (idempotent; atomic tmp+mv so concurrent containers
# never read a half-written key).
set -eu

KEYS="${KEYS_DIR:-/keys}"
mkdir -p "$KEYS"

gen() {
    name="$1"
    if [ -f "$KEYS/$name.nsec" ] && [ -f "$KEYS/$name.pub" ]; then
        echo "[keys] $name: already present"
        return 0
    fi
    out="$(/usr/local/bin/buzz-admin generate-key)" || {
        echo "[keys] buzz-admin generate-key failed" >&2
        exit 1
    }
    pub="$(printf '%s\n' "$out" | sed -n 's/^Public key:  //p')"
    sec="$(printf '%s\n' "$out" | sed -n 's/^Secret key:  //p')"
    if [ -z "$pub" ] || [ -z "$sec" ]; then
        echo "[keys] could not parse generate-key output: $out" >&2
        exit 1
    fi
    tmp_pub="$KEYS/.$name.pub.$$"
    tmp_sec="$KEYS/.$name.nsec.$$"
    printf '%s' "$pub" > "$tmp_pub"
    printf '%s' "$sec" > "$tmp_sec"
    chmod 600 "$tmp_sec"
    mv "$tmp_pub" "$KEYS/$name.pub"
    mv "$tmp_sec" "$KEYS/$name.nsec"
    echo "[keys] $name: generated"
}

# Random bearer token for the OPC control/read API. Not a Nostr key: it
# authenticates HTTP calls to event-bridge, never a relay write.
gen_token() {
    name="$1"
    if [ -s "$KEYS/$name.key" ]; then
        echo "[keys] $name: already present"
        return 0
    fi
    tmp="$KEYS/.$name.key.$$"
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$KEYS/$name.key"
    echo "[keys] $name: generated"
}

gen relay
gen agent
# Expert agents get their OWN Nostr identity. Sharing agent.nsec would make
# every expert post under the chief of staff's name — the spec calls this out
# as a hard boundary, not a nicety.
gen scientist
# The notifier is a service identity, not an agent: it has its own key so system
# notifications stop being signed by the chief of staff, and it is never given
# another identity's key. /keys stays the single producer of this file.
gen paperclip
gen_token opc-control
echo "[keys] ready"
