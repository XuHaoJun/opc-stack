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

# podenv_probe_answers <port> — a single attempt at the data-exchange probe
# described below: open the port, send a minimal HTTP GET, and require at
# least one REAL byte back within a bounded timeout.
#
# TASK-5 CORRECTION (measured false — see task-5-report.md): the previous
# form of this probe trusted `head -c 1`'s EXIT STATUS alone
# (`timeout 2 head -c 1 <&3 >/dev/null 2>/dev/null`) as proof a byte came
# back. It is not: `head -c N` exits 0 whenever it reaches EOF cleanly,
# REGARDLESS of how many bytes (including zero) it actually read — POSIX
# `head` only exits nonzero on a genuine read ERROR, and a graceful
# close/EOF is not an error. Measured directly against a container that is
# genuinely RUNNING but has nothing bound on the probed port (the exact F2
# scenario below): the surrounding `(...)` subshell exits 0 on roughly 1 in
# 7 attempts (3/20 and 3/20 in two separate 20-trial runs) with ZERO bytes
# actually captured — i.e. the read hit EOF (the far end closed cleanly)
# rather than erroring (RST), and `head` called that success anyway. Over
# this function's caller's 15-attempt/30s retry window that is roughly a
# 90% chance of at least one false "alive" — reproduced live: a gate run
# hit it and printed "restored podenv_f2_probe (verified: ... exchanged
# data ...)" for a container nothing was listening on. curl-based probes
# elsewhere in this lane (podenv's own `cmd_provision`) do not share this
# flaw — measured 0/20 false positives — because curl's exit code already
# encodes "the transfer did not go as the request demanded," where a bare
# `head` exit code does not encode "I got as many bytes as I asked for."
# Fix: capture the read into a file and require its BYTE COUNT to be >= 1,
# never trust `head`'s exit status by itself.
#
# Split out as its own function (rather than left inline in the loop below)
# so tests/podenv.sh can source this script with PODENV_RESTORE_LIB=1 and
# call this in isolation against a guaranteed-nothing-listening port — a
# tight loop of single attempts is a deterministic regression guard for the
# exact bug above, where waiting out a natural ~1-in-7 flake in the full
# gate is not.
podenv_probe_answers() {
    _pa_port="$1"
    _pa_tmp="$(mktemp)"
    ( exec 3<>"/dev/tcp/127.0.0.1/${_pa_port}" 2>/dev/null || exit 1
      printf 'GET / HTTP/1.0\r\n\r\n' >&3 2>/dev/null
      timeout 2 head -c 1 <&3 >"$_pa_tmp" 2>/dev/null
    ) 2>/dev/null
    _pa_bytes="$(wc -c <"$_pa_tmp" 2>/dev/null | tr -d '[:space:]')"
    rm -f "$_pa_tmp"
    [ "${_pa_bytes:-0}" -ge 1 ]
}

# Everything below this line is the main restore pass (wait for the socket,
# find labelled leases, force a real transition, verify each is genuinely
# alive). Guarded so tests/podenv.sh can source this file for
# podenv_probe_answers alone (PODENV_RESTORE_LIB=1) without also running a
# full restore pass as a side effect of sourcing.
[ "${PODENV_RESTORE_LIB:-0}" = 1 ] && return 0 2>/dev/null || true

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
    # daemon's recorded state, probe it.
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

    # CORRECTED (this task, previous claim measured false — see
    # task-5-report.md): this used to say a bare TCP connect (`: <
    # /dev/tcp/...`) proves the lease "answers." Measured: pasta's
    # port-forwarder completes the TCP handshake with the caller EVEN WHEN
    # NOTHING IS LISTENING on the forwarded port inside the container — it
    # accepts the connection optimistically, then makes its OWN inner
    # connect to the backend, and only resets once that inner connect fails.
    # A bare connect against a container that is genuinely RUNNING but has
    # nothing bound to its port (measured directly: an alpine lease sleeping
    # forever, never binding anything) returns success — proving only "the
    # forwarder is up," never "something answered." When the container is
    # fully exited the connect DOES correctly fail (pasta is gone with it),
    # so this only matters in the window where the container runs and the
    # daemon has not bound yet — exactly the window a legitimately slow
    # daemon (mysql initialising its data directory) passes through too, so
    # the fix cannot just fail faster; it has to look harder.
    #
    # Fix: exchange data instead of stopping at the handshake. Write a
    # syntactically-terminated minimal HTTP GET (the trailing blank line
    # matters: without it, a real HTTP server just keeps waiting for the
    # rest of a request that will never arrive, which is
    # indistinguishable from a hang) and try to read one byte back with a
    # bounded timeout. Measured against every lease shape this probe has to
    # tell apart: a running-but-unbound alpine lease fails the read almost
    # instantly ("connection reset by peer" — pasta's inner connect refused,
    # same signature every time); a genuinely dead (exited) container fails
    # to connect at all; and four real, different-protocol daemons (HTTP via
    # traefik/whoami, Redis, Postgres, MySQL) all react to the same
    # unsolicited bytes fast enough to read back at least one byte — Redis
    # and MySQL answer unsolicited or on receipt, Postgres and a real HTTP
    # server reject the garbage and close cleanly, all distinct from the
    # reset-on-nothing-bound case. A read that only times out (connection
    # open, nothing back yet) is treated as "not yet" and this keeps
    # polling, same as before the fix. See podenv_probe_answers above (task-5
    # follow-up) for why the single attempt itself has to count bytes rather
    # than trust `head`'s exit status.
    _alive=0
    _n=0
    while [ "$_n" -lt 15 ]; do
        if podenv_probe_answers "$_port"; then
            _alive=1
            break
        fi
        _n=$((_n + 1)); sleep 2
    done
    if [ "$_alive" -eq 1 ]; then
        echo "[podenv-restore] restored $_c (verified: 127.0.0.1:${_port} exchanged data, not just accepted a connection)"
    else
        echo "[podenv-restore] WARNING $_c started but 127.0.0.1:${_port} never exchanged any data after 30s (a bare connect would not prove this — see the comment above) — likely still dead; inspect by hand: docker compose exec -T -u ${PODENV_UID} -e HOME=/home/podman -e XDG_RUNTIME_DIR=/run/user/${PODENV_UID} podenv podman logs $_c" >&2
    fi
done
exit 0
