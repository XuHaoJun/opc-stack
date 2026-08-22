#!/bin/sh
# opc-podenv-restore.sh — bring leased containers back after a restart.
#
# Backgrounded by the entrypoint. It has to be: the socket it waits for is
# created by the process the entrypoint is about to exec, so running this in
# the foreground would deadlock the boot. Same shape and same reason as
# opc-prototype-restore.sh in the paperclip image.
#
# Why an explicit start rather than --restart=always: podman's restart policy
# needs podman to be alive to act on it, and every boot is a NEW service
# process. The label plus this loop is the mechanism, not a safety net.
#
# Unlike prototype-restore, liveness needs no probing. Those preview servers
# were children of a server whose database still claimed `running` long after
# the process died. Here the containers ARE this service's descendants: if the
# service is up and podman lists them, they exist.
#
# Never fatal: this is recovery. Every lease is also restartable by hand with
# `podman start <slug>`.
set -u

PODENV_UID="${PODENV_UID:-1000}"
PODENV_GID="${PODENV_GID:-1000}"
PODENV_SOCK_DIR="${PODENV_SOCK_DIR:-/run/podenv}"
PODENV_SOCK="${PODENV_SOCK_DIR}/podman.sock"

_n=0
while [ ! -S "$PODENV_SOCK" ] && [ "$_n" -lt 60 ]; do
    _n=$((_n + 1)); sleep 2
done
if [ ! -S "$PODENV_SOCK" ]; then
    echo "[podenv-restore] socket never appeared — nothing restored" >&2
    exit 0
fi

_ids="$(setpriv --reuid "$PODENV_UID" --regid "$PODENV_GID" --clear-groups \
    env HOME=/home/podman XDG_RUNTIME_DIR="/run/user/${PODENV_UID}" \
    podman ps -a --filter label=opc.podenv.lease --format '{{.Names}}' 2>/dev/null)"
[ -n "$_ids" ] || { echo "[podenv-restore] no leases to restore"; exit 0; }

for _c in $_ids; do
    if setpriv --reuid "$PODENV_UID" --regid "$PODENV_GID" --clear-groups \
        env HOME=/home/podman XDG_RUNTIME_DIR="/run/user/${PODENV_UID}" \
        podman start "$_c" >/dev/null 2>&1; then
        echo "[podenv-restore] started $_c"
    else
        echo "[podenv-restore] WARNING could not start $_c — run 'podman start $_c' to see why" >&2
    fi
done
exit 0
