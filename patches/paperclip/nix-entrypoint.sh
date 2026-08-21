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

# Assert that everything the runtime user must write is owned by the runtime
# user — whoever created it.
#
# A container has two entry paths with different identities: this entrypoint
# (root, then gosu node) and `docker compose exec` (always root). Both touch
# the same trees, and whoever creates a path first owns it. Nothing in Docker
# reconciles that, so the invariant has to be asserted somewhere.
#
# It is worth asserting because none of the symptoms look like permissions:
# git reports "dubious ownership" and then silently commits nothing; Next fails
# with EACCES on .next/dev surfacing only as a 500 from the runtime-service API;
# pnpm reports "attempt to write a readonly database" from its store index.
# Each one cost a debugging session to trace back to a uid.
#
# First-mismatch probe then repair, the same shape upstream's docker-entrypoint
# uses for /paperclip: a correct tree costs one metadata walk that stops at the
# first hit, and only a wrong one pays for chown -R.
opc_own_runtime_trees() {
    for _t in /prototypes "${HOME:-/paperclip}/.cache" "${HOME:-/paperclip}/.local"; do
        [ -d "$_t" ] || continue
        if [ -n "$(find "$_t" \( ! -user node -o ! -group node \) -print -quit 2>/dev/null)" ]; then
            echo "[own] repairing ownership under $_t"
            chown -R node:node "$_t" 2>/dev/null || true
        fi
    done
}
mkdir -p /prototypes
opc_own_runtime_trees

# devenv control DB + schema (optional lane; never fatal).
. /usr/local/bin/opc-devenv-seed.sh
opc_devenv_seed

# podenv's own table in that same database (optional lane; never fatal).
# Ordered AFTER the devenv seed because that one creates the database.
. /usr/local/bin/opc-podenv-seed.sh
opc_podenv_seed

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
