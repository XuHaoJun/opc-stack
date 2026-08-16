#!/bin/sh
# opc-mise-seed.sh — source from an OPC entrypoint AFTER opc-nix-seed.sh
# (mise binary comes from the nix profile, so nix PATH must be active first).
#
# Ensures the mise-managed toolchains exist on the persistent *-mise volume:
# node@lts, rust@stable, and omp (prebuilt from GitHub releases — the nix
# derivation for omp cannot build in image environments, bun EPERM). Installs
# only when a toolchain is missing (fresh volume / down -v); existing
# installs are left untouched. Per-tool check → a failed install retries on
# next boot without touching the others.
# PATH tail: baked node stays authoritative (hermes 26 / paperclip 24);
# mise fills gaps (cargo/rustc everywhere, node in buzz, omp).
opc_mise_seed() {
    export MISE_DATA_DIR="${MISE_DATA_DIR:-/opt/mise}"
    export MISE_CACHE_DIR="${MISE_CACHE_DIR:-/opt/mise/cache}"
    export MISE_CONFIG_DIR="${MISE_CONFIG_DIR:-/opt/mise/config}"
    export PATH="$PATH:$MISE_DATA_DIR/shims"

    if [ ! -d "$MISE_DATA_DIR/installs/node" ]; then
        echo "[mise] first boot: installing node@lts (global)"
        mise use -g node@lts || echo "[mise] node install failed (network?)" >&2
    fi
    if [ ! -d "$MISE_DATA_DIR/installs/rust" ]; then
        echo "[mise] first boot: installing rust@stable (global, rustup)"
        mise use -g rust@stable || echo "[mise] rust install failed (network?)" >&2
        # core:rust backend leaves installs/rust/stable as a symlink into
        # $HOME/.cargo/bin; mise 2026.8.3 only generates the rustc/cargo/rustup
        # shims on tool activation, not at install. Activate once so the shims
        # exist on the volume for the daemon PATH (otherwise `rustc`/`cargo`
        # are "not found" until something runs `mise x` for rust).
        mise x rust@stable -- true || echo "[mise] rust shim activation failed" >&2
    fi
    if [ ! -d "$MISE_DATA_DIR/installs/github-can1357-oh-my-pi" ]; then
        echo "[mise] first boot: installing omp (prebuilt, github releases)"
        mise use -g github:can1357/oh-my-pi@17.3.5 || echo "[mise] omp install failed (network?)" >&2
    fi
}
