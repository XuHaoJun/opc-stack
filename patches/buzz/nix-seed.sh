#!/bin/sh
# opc-nix-seed.sh — source from an OPC entrypoint.
#
# Docker hides an image's /nix when an (empty) named volume is mounted over
# it. This seeds the volume from the /nix-seed copy baked into the image on
# first boot and re-links the root user's profile symlink every boot.
#
# Persistent tool usage (use `add`, not the deprecated `install` alias):
#   docker exec <container> nix profile add nixpkgs#<tool>
#   -> binaries land in /nix/var/nix/profiles/per-user/root/profile/bin,
#      which is already on PATH; they survive compose down/up + recreate.
opc_nix_seed() {
    PROFILE="/nix/var/nix/profiles/per-user/root/profile"

    if [ ! -e /nix/var/nix/db/db.sqlite ]; then
        echo "[nix] first boot: seeding persistent /nix volume from /nix-seed"
        mkdir -p /nix
        cp -a /nix-seed/. /nix/ || true
    fi

    _home="${HOME:-/root}"
    if [ ! -e "$_home/.nix-profile" ]; then
        ln -sfn "$PROFILE" "$_home/.nix-profile"
    fi
    export NIX_USER_CONF_FILES="${NIX_USER_CONF_FILES:-/nix/etc/nix/nix.conf}"
    export NIX_SSL_CERT_FILE="${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"
    export PATH="$PROFILE/bin:/nix/var/nix/profiles/default/bin:$PATH"
    export NIX_PROFILES="/nix/var/nix/profiles/default /nix/var/nix/profiles/per-user/root"

    # Self-heal: if the profile somehow lacks the default tools (e.g. the
    # deprecated `nix profile install` replaced it), re-add them once.
    if [ ! -e "$PROFILE/bin/rg" ]; then
        echo "[nix] default tools missing from profile; re-adding"
        HOME=/root PATH="/nix/var/nix/profiles/default/bin:$PATH" \
            nix profile add nixpkgs#ripgrep nixpkgs#jq nixpkgs#fd nixpkgs#htop nixpkgs#bat || true
    fi

    # omp default model (used when omp runs inside this container).
    _omp_cfg="${OMP_CONFIG_DIR:-${HOME:-/root}/.omp}/agent/config.yml"
    if [ ! -f "$_omp_cfg" ]; then
        mkdir -p "$(dirname "$_omp_cfg")"
        cat > "$_omp_cfg" <<'YAML'
modelRoles:
  default: opencode-go/deepseek-v4-pro
startup:
  quiet: true
YAML
        echo "[nix] seeded omp config: model=opencode-go/deepseek-v4-pro"
    fi
}
