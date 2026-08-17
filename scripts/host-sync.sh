#!/usr/bin/env bash
# host-sync.sh — generic host→volume config mirror (host CLI).
#
# Runs the host-sync-worker in a throwaway alpine container: binds a named
# volume at /dst (the worker's fixed target), each declared host path
# read-only at /src/<name>, optional per-source transform scripts at
# /hooks/<name>.sh, and the worker itself. Stdin passes through to the
# container (a hook may consume it, e.g. ssh-keyscan output).
#
#   host-sync.sh --volume <compose-key> \
#                --src <name>=<hostpath>... \
#                [--hook <name>=<script>...]
#
#   # example (gh creds):
#   ssh-keyscan github.com | host-sync.sh --volume opc-gh-creds \
#       --src ssh="$HOME/.ssh" --src gh="$HOME/.config/gh" \
#       --src gitconfig="$HOME/.gitconfig" \
#       --hook ssh=scripts/hooks/ssh.sh \
#       --hook gitconfig=scripts/hooks/gitconfig.sh
#
# Idempotent. Warns for missing sources and still syncs what exists, but
# exits non-zero so a partial sync is visible.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="alpine:3.20"
VOLUME=""
SRCS=()
HOOKS=()

usage() {
    echo "usage: host-sync.sh --volume <compose-key> --src <name>=<hostpath> [--hook <name>=<script>]" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --volume) VOLUME="${2:?}"; shift 2 ;;
        --src)    SRCS+=("${2:?}"); shift 2 ;;
        --hook)   HOOKS+=("${2:?}"); shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$VOLUME" ] && [ "${#SRCS[@]}" -gt 0 ] || usage

# Compose prefixes every named volume with the resolved project name
# (.env COMPOSE_PROJECT_NAME, default "opc"), so the compose key
# "opc-gh-creds" becomes e.g. "opc_opc-gh-creds". Resolve it via compose
# itself; fall back to the env var.
PROJECT="$(docker compose config 2>/dev/null | sed -n 's/^name: *\(.*\)$/\1/p' | head -1)"
[ -n "$PROJECT" ] || PROJECT="${COMPOSE_PROJECT_NAME:-opc}"
VOLNAME="${PROJECT}_${VOLUME}"

MISSING=0
BINDS=(-v "${VOLNAME}:/dst")
HOST_SYNC_SOURCES=""
for spec in "${SRCS[@]}"; do
    name="${spec%%=*}"
    path="${spec#*=}"
    [ -n "$name" ] || { echo "ERROR: --src must be <name>=<hostpath>, got '$spec'" >&2; exit 1; }
    HOST_SYNC_SOURCES+="${name} "
    if [ ! -e "$path" ]; then
        echo "WARN: ${path} (${name}) missing — skipped, sync will be partial" >&2
        MISSING=1
        continue
    fi
    BINDS+=(-v "${path}:/src/${name}:ro")
done
for spec in "${HOOKS[@]}"; do
    name="${spec%%=*}"
    script="${spec#*=}"
    [ -f "$script" ] || { echo "ERROR: hook script '$script' not found" >&2; exit 1; }
    BINDS+=(-v "$(pwd)/${script}:/hooks/${name}.sh:ro")
done
BINDS+=(-v "$(pwd)/scripts/host-sync-worker.sh:/worker.sh:ro")

# Stdin passes through to the container; detach a TTY so hooks that read
# stdin (e.g. the ssh hook's `cat >> known_hosts`) hit EOF, not a prompt.
if [ -t 0 ]; then
    if ! docker run --rm -i "${BINDS[@]}" -e HOST_SYNC_SOURCES="$HOST_SYNC_SOURCES" "$IMAGE" sh /worker.sh < /dev/null; then
        echo "ERROR: sync container failed — is the ${VOLNAME} volume created? (docker compose up -d first, or docker volume create ${VOLNAME})" >&2
        exit 1
    fi
else
    if ! docker run --rm -i "${BINDS[@]}" -e HOST_SYNC_SOURCES="$HOST_SYNC_SOURCES" "$IMAGE" sh /worker.sh; then
        echo "ERROR: sync container failed — is the ${VOLNAME} volume created? (docker compose up -d first, or docker volume create ${VOLNAME})" >&2
        exit 1
    fi
fi

echo "OK  synced → ${VOLNAME} (worker target /dst; consumers mount the volume where their entrypoints expect it)"
[ "${MISSING}" -eq 0 ]
