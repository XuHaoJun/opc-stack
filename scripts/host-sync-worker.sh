#!/bin/sh
# host-sync-worker.sh — generic host→volume mirror engine (container-side).
#
# Mirrors declared host sources into a named volume mounted at /dst:
#   - env HOST_SYNC_SOURCES = space-separated source names (e.g. "ssh gh gitconfig")
#   - each source is mounted read-only at /src/<name> by the runner
#   - each name is copied to /dst/<name> (dir contents or single file)
#   - an optional per-source transform at /hooks/<name>.sh runs after the copy
#     (it defines the final layout/format of that source in the volume)
#   - stdin passes through to hooks (a hook may consume it, e.g. ssh-keyscan)
#
# Idempotent: every run re-mirrors from scratch. Runs under `sh` in alpine
# (cp/sed/grep/chmod only). New use-cases need no engine changes: declare a
# source and optionally a hook.
set -eu

for N in ${HOST_SYNC_SOURCES}; do
    if [ ! -e "/src/${N}" ]; then
        echo "ERROR: /src/${N} not mounted — runner must bind a host path" >&2
        exit 1
    fi
    rm -rf "/dst/${N}"
    mkdir -p "/dst/${N}"
    if [ -d "/src/${N}" ]; then
        cp -a "/src/${N}/." "/dst/${N}/"
    else
        cp -a "/src/${N}" "/dst/${N}"
    fi
    if [ -f "/hooks/${N}.sh" ]; then
        "/hooks/${N}.sh"
    fi
done
