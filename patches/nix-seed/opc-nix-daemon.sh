#!/bin/sh
# opc-nix-daemon.sh — the single multi-user nix-daemon for the whole stack.
#
# Why a separate service instead of a daemon per container: the store is ONE
# shared volume (opc-nix). Nix assumes one daemon per store, and a unix socket
# living on a shared volume is reachable from every container that mounts it
# (verified: daemon in `hermes`, client in `hermes-dashboard`, uid 10000,
# `Store URL: daemon`). So one daemon serves all of them.
#
# This process owns everything that must have exactly one writer:
#   1. seeding the shared volume from the image's /nix-seed
#   2. healing the root (system) profile's tool list
#   3. creating the group-writable shared agent profile
#   4. publishing the nix-add / nix-rm / nix-list wrappers
#
# Consumers only set env (see each project's opc-nix-seed.sh) and wait for the
# socket via `depends_on: nix-daemon: service_healthy`.
set -e

SEED=/nix-seed
ROOT_PROFILE=/nix/var/nix/profiles/per-user/root/profile
AGENTS_DIR=/nix/var/nix/profiles/opc-agents
AGENTS_PROFILE="$AGENTS_DIR/profile"
OPC_BIN=/nix/var/nix/opc-bin
# Must match the `nixagents` group baked into every service image. Compared
# NUMERICALLY across the shared volume — the name is irrelevant there.
NIXAGENTS_GID=3000
# Must stay equal to the rev the Dockerfile seeds from, so the self-heal below
# reinstates exactly what a clean machine got.
NIXPKGS=github:NixOS/nixpkgs/8be7bd0c83f1

export NIX_SSL_CERT_FILE="${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"
export PATH="/nix/var/nix/profiles/default/bin:$PATH"

# ── 1. Seed the shared volume ────────────────────────────────────────────
# Docker hides the image's /nix behind the (empty) named volume on first boot.
if [ ! -e /nix/var/nix/db/db.sqlite ]; then
    echo "[nix-daemon] first boot: seeding shared /nix volume from $SEED"
    cp -a "$SEED"/. /nix/
fi

# ── 2. Client-facing nix.conf lives on the volume ────────────────────────
# Consumers point NIX_USER_CONF_FILES here. Keep it free of restricted
# settings (`sandbox`, `trusted-users`, ...): an unprivileged client that
# names one gets "ignoring the client-specified setting" on EVERY nix
# invocation, which is pure noise in an agent's transcript. The daemon's own
# copy at /etc/nix/nix.conf (image layer) carries those.
mkdir -p /nix/etc/nix
printf 'experimental-features = nix-command flakes\n' > /nix/etc/nix/nix.conf

# ── 3. Heal the system profile ───────────────────────────────────────────
# Single owner on purpose: this used to run in every container's entrypoint,
# which against ONE shared store would mean four concurrent writers to the
# same profile. Detection reads the profile path directly rather than
# `command -v` so a shadowing entry on PATH cannot fake a tool's presence.
# Add every NEW seed tool to this condition or existing volumes never get it.
if [ ! -e "$ROOT_PROFILE/bin/rg" ] || [ ! -e "$ROOT_PROFILE/bin/mise" ] \
    || [ ! -e "$ROOT_PROFILE/bin/just" ] || [ ! -e "$ROOT_PROFILE/bin/gh" ] \
    || [ ! -e "$ROOT_PROFILE/bin/ps" ] || [ ! -e "$ROOT_PROFILE/bin/ss" ] \
    || [ ! -e "$ROOT_PROFILE/bin/psql" ]; then
    echo "[nix-daemon] seed tools missing from system profile; re-adding"
    # Same pinned rev as the Dockerfile's seed install. Bare `nixpkgs#` would
    # resolve through the flake registry to whatever unstable is today, so the
    # heal would (a) need to fetch and build a second copy of tools the store
    # already has and (b) hand an existing volume different versions from the
    # ones a clean machine gets.
    HOME=/root nix profile add --profile "$ROOT_PROFILE" \
        "$NIXPKGS#ripgrep" "$NIXPKGS#jq" "$NIXPKGS#fd" "$NIXPKGS#htop" "$NIXPKGS#bat" \
        "$NIXPKGS#just" "$NIXPKGS#mise" "$NIXPKGS#gh" \
        "$NIXPKGS#procps" "$NIXPKGS#iproute2" "$NIXPKGS#lsof" "$NIXPKGS#postgresql" || true
fi

# ── 4. Shared agent profile ──────────────────────────────────────────────
# One profile every agent adds to, so "installed once, visible everywhere"
# holds. setgid keeps new generations group-owned; the directory (not the
# symlinks in it) is what needs to be writable, since adding a generation
# means creating/replacing links inside it.
mkdir -p "$AGENTS_DIR"
chgrp "$NIXAGENTS_GID" "$AGENTS_DIR"
chmod 2775 "$AGENTS_DIR"

# ── 5. Publish the wrappers ──────────────────────────────────────────────
# Agents MUST install through these, not through a bare `nix profile add`.
# Two reasons, in order of importance:
#
#   1. A bare add targets the caller's OWN profile, which is not on anyone
#      else's PATH — "install once, everyone gets it" silently fails.
#   2. A bare add leaves $HOME/.nix-profile resolving all the way into
#      /nix/store. hermes-dashboard's Files page builds its listing in a list
#      comprehension with no per-entry guard (web_server.py:2562-2567) and
#      403s any entry resolving outside the managed root (:2425), so ONE such
#      symlink in /opt/data kills the whole directory listing. With an
#      explicit --profile the compat symlink points at an as-yet-nonexistent
#      path *inside* $HOME, so it never escapes. (Verified both ways.)
#
# They live on the volume rather than in each image so there is one copy to
# change, and every container picks it up on the next daemon restart.
mkdir -p "$OPC_BIN"

cat > "$OPC_BIN/nix-add" <<EOF
#!/bin/sh
# Install into the stack-wide shared nix profile. Visible in EVERY container.
if [ \$# -eq 0 ]; then
    echo "usage: nix-add nixpkgs#<tool> [nixpkgs#<tool> ...]" >&2
    exit 2
fi
exec nix profile add --profile "$AGENTS_PROFILE" "\$@"
EOF

cat > "$OPC_BIN/nix-rm" <<EOF
#!/bin/sh
# Remove from the stack-wide shared nix profile. Affects EVERY container.
exec nix profile remove --profile "$AGENTS_PROFILE" "\$@"
EOF

cat > "$OPC_BIN/nix-list" <<EOF
#!/bin/sh
# What the stack has collectively installed.
exec nix profile list --profile "$AGENTS_PROFILE" "\$@"
EOF

chmod 0755 "$OPC_BIN/nix-add" "$OPC_BIN/nix-rm" "$OPC_BIN/nix-list"

echo "[nix-daemon] ready: store=/nix/store shared-profile=$AGENTS_PROFILE"
exec /nix/var/nix/profiles/default/bin/nix-daemon
