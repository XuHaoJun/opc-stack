#!/bin/sh
# opc-podenv-entrypoint.sh — the podenv lane's runtime host.
#
# Starts the rootless podman API service that `podenv` (in the paperclip
# image) leases containers from. Root only long enough to hand three trees to
# the runtime user, then drops for good.
#
# The socket keeps podman's OWN 0600 mode and we do not fight it. Its access
# gate is the OWNER uid, deliberately aligned with paperclip's `node` (uid
# 1000). Measured: podman re-chmods the socket to 0600 AFTER creating the
# listener, so granting group access races and loses — a retry loop was
# observed reporting success (stat really did read 660) and then being
# reverted. See the spec's measurement 3.
set -eu

PODENV_UID="${PODENV_UID:-1000}"
PODENV_GID="${PODENV_GID:-1000}"
PODENV_SOCK_DIR="${PODENV_SOCK_DIR:-/run/podenv}"
PODENV_STORE="${PODENV_STORE:-/home/podman/.local/share/containers}"
PODENV_RUNTIME_DIR="/run/user/${PODENV_UID}"
PODENV_DIAG="${PODENV_SOCK_DIR}/diagnosis"

mkdir -p "$PODENV_SOCK_DIR" "$PODENV_STORE" "$PODENV_RUNTIME_DIR"
chown "$PODENV_UID:$PODENV_GID" "$PODENV_SOCK_DIR" "$PODENV_STORE" "$PODENV_RUNTIME_DIR"
# 0700: a second, independent gate. Measured — a process with the right uid but
# no traverse on this directory is refused before the socket mode matters.
chmod 0700 "$PODENV_SOCK_DIR"

as_runtime_user() {
    setpriv --reuid "$PODENV_UID" --regid "$PODENV_GID" --clear-groups --inh-caps=-all \
        env HOME=/home/podman XDG_RUNTIME_DIR="$PODENV_RUNTIME_DIR" "$@"
}

# Self-test, and WRITE THE VERDICT DOWN. A nested runtime that cannot start
# produces errors that mean nothing to the caller ("cannot clone: Operation not
# permitted", "Failed to open() /dev/net/tun"); the CLI reads this file so the
# operator gets one sentence instead of a nested stack trace.
#
# Never fatal. podenv is an optional lane and paperclip has no depends_on edge
# to it: a broken runtime host must degrade to "leases fail when used", not to
# "the stack does not come up" (invariant 8's lesson).
: > "$PODENV_DIAG"
chown "$PODENV_UID:$PODENV_GID" "$PODENV_DIAG"

if ! _st_out="$(as_runtime_user podman unshare true 2>&1)"; then
    printf 'userns nesting failed: %s\n' "$_st_out" > "$PODENV_DIAG"
    echo "[podenv] WARNING userns nesting failed — every lease will fail." >&2
    echo "[podenv] WARNING   $_st_out" >&2
    echo "[podenv] WARNING   Check that this service still has security_opt: [seccomp=unconfined]," >&2
    echo "[podenv] WARNING   and that the host allows unprivileged user namespaces." >&2
elif [ ! -c /dev/net/tun ]; then
    printf 'no /dev/net/tun: pasta unavailable, leases must pass --netns host\n' > "$PODENV_DIAG"
    echo "[podenv] WARNING /dev/net/tun is missing — pasta cannot start, so port" >&2
    echo "[podenv] WARNING   remapping (-p) is unavailable. Leases must pass --netns host." >&2
    echo "[podenv] WARNING   No silent fallback: a lease that thinks it has its own netns" >&2
    echo "[podenv] WARNING   but shares the sidecar's would collide invisibly." >&2
fi

# Leased containers are this service's descendants, so they died with the
# previous instance of it. Backgrounded because it waits for the socket the
# exec below creates.
#
# Double-forked (the outer parens are a SYNCHRONOUS subshell, not backgrounded
# themselves) rather than a plain trailing `&`: this process is about to exec
# into podman, which becomes the direct parent of anything merely
# background-forked here and never wait()s on children it did not itself
# spawn. Measured: a plain `&` left the restore script as a permanent zombie
# (ppid = the exec'd podman process) once it finished, defeating the exact
# zombie-reaping invariant `init: true` exists for (see compose file). The
# subshell here exits immediately after backgrounding the real script, so the
# script is orphaned to, and reaped by, PID 1 (docker-init) instead — the
# entrypoint shell foreground-waits for the subshell itself, so that layer
# leaves no zombie either.
( PODENV_UID="$PODENV_UID" PODENV_GID="$PODENV_GID" PODENV_SOCK_DIR="$PODENV_SOCK_DIR" \
    /usr/local/bin/opc-podenv-restore.sh & )

# Spelled out rather than reusing as_runtime_user(): `exec` cannot run a shell
# function, and this process must be REPLACED — a setpriv running under a
# surviving shell would make the shell PID 1, so podman would not receive the
# signals docker sends it on `compose stop`.
exec setpriv --reuid "$PODENV_UID" --regid "$PODENV_GID" --clear-groups --inh-caps=-all \
    env HOME=/home/podman XDG_RUNTIME_DIR="$PODENV_RUNTIME_DIR" \
    podman system service --time=0 "unix://${PODENV_SOCK_DIR}/podman.sock"
