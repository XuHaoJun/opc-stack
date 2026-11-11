#!/bin/sh
# opc-nix-seed.sh — source from an OPC entrypoint.
#
# The store itself is NOT owned here. One shared volume (opc-nix) is served by
# one multi-user daemon (compose service `nix-daemon`, see
# patches/nix-seed/opc-nix-daemon.sh), and that daemon owns everything needing
# a single writer: seeding, system-profile self-heal, the shared agent
# profile, and the nix-add/nix-rm/nix-list wrappers. Four containers healing
# the same profile concurrently is exactly the race that ownership split
# avoids. This script only wires up the client side.
#
# Installing tools:
#   agents  ->  nix-add nixpkgs#<tool>      (shared profile; lands in EVERY
#                                            container, survives recreate)
#   system  ->  docker exec <c> nix profile add nixpkgs#<tool>
#               (root's profile — the layer agents cannot touch)
#
# Never apt-get: apt writes to the container layer and `up -d --build` or a
# recreate silently throws it away. nix writes to the volume and survives.
opc_nix_seed() {
    PROFILE="/nix/var/nix/profiles/per-user/root/profile"
    AGENTS_PROFILE="/nix/var/nix/profiles/opc-agents/profile"
    OPC_BIN="/nix/var/nix/opc-bin"

    # Fallback seed only. Containers that mount opc-nix get a volume the
    # nix-daemon service already seeded (they wait on its healthcheck); this
    # branch is for the ones that mount no nix volume at all (e.g. buzz-keys),
    # where /nix is a throwaway container layer.
    if [ ! -e /nix/var/nix/db/db.sqlite ]; then
        echo "[nix] no shared store visible: seeding local /nix from /nix-seed"
        mkdir -p /nix
        cp -a /nix-seed/. /nix/ || true
    fi

    # Root keeps pointing at the SYSTEM profile, so `docker exec <c> nix
    # profile add` still means "install for everyone, permanently" as
    # documented in SETUP.md. Agents go through nix-add instead, which targets
    # the shared profile explicitly.
    _home="${HOME:-/root}"
    if [ ! -e "$_home/.nix-profile" ]; then
        ln -sfn "$PROFILE" "$_home/.nix-profile"
    fi

    export NIX_USER_CONF_FILES="${NIX_USER_CONF_FILES:-/nix/etc/nix/nix.conf}"
    export NIX_SSL_CERT_FILE="${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"
    # Same order as the image ENV: system profile first (agents must not be
    # able to shadow a seed tool), then the shared agent profile, then the
    # wrapper dir.
    export PATH="$PROFILE/bin:$AGENTS_PROFILE/bin:$OPC_BIN:/nix/var/nix/profiles/default/bin:$PATH"
    export NIX_PROFILES="/nix/var/nix/profiles/default /nix/var/nix/profiles/per-user/root $AGENTS_PROFILE"

    # omp model, for every omp invocation inside this container. opc-model-seed
    # writes a custom provider from OPENAI_BASE_URL/OPENAI_MODEL instead of
    # pinning a built-in provider slug, so omp follows .env like hermes does.
    command -v opc_omp_seed >/dev/null 2>&1 || . /usr/local/bin/opc-model-seed.sh
    opc_omp_seed
}
