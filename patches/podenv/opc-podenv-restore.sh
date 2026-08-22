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
# CORRECTED (previous claim measured false — see task-5-report.md): this
# script used to say liveness needs no probing because "the containers ARE
# this service's descendants: if the service is up and podman lists them,
# they exist." Measured, on `docker compose restart podenv`: podman goes on
# reporting a lease "Up" with a live-looking uptime, `podman ps --sync` does
# not correct it, and a plain `podman start` on it returns success WITHOUT
# reviving anything — the recorded pid is gone from /proc and nothing answers
# on the port. `podman restart` is not the fix either — it fails outright on
# exactly this state ("conmon exited prematurely, exit code could not be
# retrieved: conmon process killed"). The cause (unverified beyond this): the
# outer container's PID namespace is torn down on `restart`, but `restart`
# preserves its writable layer, and podman's rootless runtime state under
# /run/user/<uid> lives in that layer (not a tmpfs mount — confirmed via
# /proc/mounts), so podman keeps believing the old instance is alive.
# `--force-recreate` builds a fresh writable layer, which is why plain
# `start` happens to work there — but this script cannot assume which path
# brought it up, so it never trusts recorded state at all: force a real
# transition, then verify the lease is actually reachable before calling it
# restored.
#
# Never fatal: this is recovery. Every lease is also restartable by hand with
# `podman start <slug>`.
#
# SIBLING BUG, SIBLING FIX — the two must stay in agreement: the exact same
# false-authoritative-state bug existed in `podenv provision`'s idempotent
# re-provision branch (patches/paperclip/podenv/podenv, "container exists"
# branch), and was worse there because it is the DOCUMENTED, routine path an
# agent is told to run freely. It is fixed there the same way: force
# `stop -t 0` then `start`, then verify liveness before reporting success,
# never `podman restart`. The two cannot share a file (different images), so
# if the measured behaviour above ever needs revising, revise the comment in
# both places — this repo has been burned by exactly this kind of drift
# before (see AGENTS.md's note on the two `SOUL.md` and two `paperclip-api`
# SKILL.md copies).
set -u

PODENV_UID="${PODENV_UID:-1000}"
PODENV_GID="${PODENV_GID:-1000}"
PODENV_SOCK_DIR="${PODENV_SOCK_DIR:-/run/podenv}"
PODENV_SOCK="${PODENV_SOCK_DIR}/podman.sock"

podman_r() {
    setpriv --reuid "$PODENV_UID" --regid "$PODENV_GID" --clear-groups \
        env HOME=/home/podman XDG_RUNTIME_DIR="/run/user/${PODENV_UID}" \
        podman "$@"
}

_n=0
while [ ! -S "$PODENV_SOCK" ] && [ "$_n" -lt 60 ]; do
    _n=$((_n + 1)); sleep 2
done
if [ ! -S "$PODENV_SOCK" ]; then
    echo "[podenv-restore] socket never appeared — nothing restored" >&2
    exit 0
fi

_ids="$(podman_r ps -a --filter label=opc.podenv.lease --format '{{.Names}}' 2>/dev/null)"
[ -n "$_ids" ] || { echo "[podenv-restore] no leases to restore"; exit 0; }

for _c in $_ids; do
    # Force a real state transition rather than trusting whatever podman
    # currently believes. `stop -t 0` is harmless on a container that really
    # is already stopped; on the stale-"Up" case it is measured to print a
    # loud error ("conmon exited prematurely...") and still land the
    # container in a state `start` can act on — that error is expected and
    # ignored here. Never `podman restart`: measured to fail outright on
    # exactly this state.
    podman_r stop -t 0 "$_c" >/dev/null 2>&1

    if ! podman_r start "$_c" >/dev/null 2>&1; then
        echo "[podenv-restore] WARNING $_c did not start — investigate: docker compose exec -T -u ${PODENV_UID} -e HOME=/home/podman -e XDG_RUNTIME_DIR=/run/user/${PODENV_UID} podenv podman start $_c" >&2
        continue
    fi

    # `start` returning 0 is not proof of life (see header) — verify by
    # actually reaching the lease's own published port, the same standard
    # opc-prototype-restore.sh holds preview servers to: never trust a
    # daemon's recorded state, probe it. A bare TCP connect (not an HTTP
    # request) is the probe, since a lease can be any protocol podenv leases
    # out (postgres, redis, mysql, ...), not just HTTP.
    _portline="$(podman_r port "$_c" 2>/dev/null | head -1)"
    _port="$(printf '%s' "$_portline" | sed -n 's/.*:\([0-9]\+\)[[:space:]]*$/\1/p')"
    if [ -z "$_port" ]; then
        # --netns host leases publish no port at all (measured: -p is
        # discarded for that mode, so `podman port` has nothing to report).
        # There is nothing here this script can probe — say so rather than
        # silently counting it as restored.
        echo "[podenv-restore] WARNING $_c started but publishes no port (--netns host) — cannot verify liveness by probing; check by hand: docker compose exec -T -u ${PODENV_UID} -e HOME=/home/podman -e XDG_RUNTIME_DIR=/run/user/${PODENV_UID} podenv podman logs $_c" >&2
        continue
    fi

    _alive=0
    _n=0
    while [ "$_n" -lt 15 ]; do
        if timeout 2 sh -c ": < /dev/tcp/127.0.0.1/${_port}" 2>/dev/null; then
            _alive=1
            break
        fi
        _n=$((_n + 1)); sleep 2
    done
    if [ "$_alive" -eq 1 ]; then
        echo "[podenv-restore] restored $_c (verified: 127.0.0.1:${_port} answers)"
    else
        echo "[podenv-restore] WARNING $_c started but 127.0.0.1:${_port} never answered after 30s — likely still dead; inspect by hand: docker compose exec -T -u ${PODENV_UID} -e HOME=/home/podman -e XDG_RUNTIME_DIR=/run/user/${PODENV_UID} podenv podman logs $_c" >&2
    fi
done
exit 0
