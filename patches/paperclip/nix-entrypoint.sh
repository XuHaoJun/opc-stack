#!/bin/sh
# Paperclip entrypoint: seed the /nix volume, then hand off to the upstream
# docker-entrypoint.sh (uid remap + gosu node) with the original CMD.
set -eu

. /usr/local/bin/opc-nix-seed.sh
opc_nix_seed

# Mise toolchains: node@lts + rust@stable + omp on the *-mise volume.
. /usr/local/bin/opc-mise-seed.sh
opc_mise_seed

. /usr/local/bin/opc-gh-seed.sh
opc_gh_seed

# Prototyper agent home (Claude Code credential only — see the script).
. /usr/local/bin/opc-claude-seed.sh
opc_claude_seed

# Prototype working trees. Paperclip does not create a local_path workspace's
# cwd, and the volume arrives root-owned, so make the root writable by the
# runtime user before anything tries to use it.
if [ -d /prototypes ]; then
    chown node:node /prototypes 2>/dev/null || true
fi

# devenv control DB + schema (optional lane; never fatal).
. /usr/local/bin/opc-devenv-seed.sh
opc_devenv_seed

# The runtime server (and the omp executor it spawns) runs as the `node`
# user via gosu. The nix-seed creates /paperclip/.omp as root (HOME=/paperclip
# at entrypoint time) — hand it to node so omp's SQLite state opens cleanly.
if [ -d /paperclip/.omp ]; then
    chown -R node:node /paperclip/.omp 2>/dev/null || true
fi

# Preview servers die with the container; nothing in paperclip brings them
# back. Waits for the API in the background (it is served by the process we
# exec below) and restarts whatever desiredState says should be running.
. /usr/local/bin/opc-prototype-restore.sh
opc_prototype_restore_bg

exec "$@"
