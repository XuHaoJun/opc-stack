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
# brought it up, so it never trusts recorded state at all.
#
# CORRECTED AGAIN (task-5 review F1, previous fix in this file measured to
# be a regression, not just a wart): "never trust recorded state" got
# implemented as an UNCONDITIONAL `stop -t 0` (no grace period) on every
# matching container BEFORE checking anything. At container boot that is
# nearly free — every lease really is dead by then (the PID namespace that
# held its real process is gone). But the sibling branch in
# `patches/paperclip/podenv/podenv` runs this exact shape ON DEMAND, as the
# documented, encouraged way for an agent to "pick a lease back up" — and
# `stop -t 0` there SIGKILLs a live daemon mid-operation. RED-proved live in
# this repo's own stack (task-5-report.md): a genuinely healthy, serving
# `traefik/whoami` lease was re-provisioned (the routine, idempotent path)
# and its `podman inspect --format {{.State.StartedAt}}` jumped forward by
# ~10 seconds across the call — killed and restarted for no reason, even
# though it never stopped answering. For a real stateful daemon (mysql
# mid-write) that is strictly worse than the silent-dead-lease bug this
# mechanism replaced.
#
# Fix: PROBE FIRST. A healthy lease answers immediately, so checking before
# disrupting costs nothing in the common case, and it is the only way this
# script can tell "genuinely running" from podman's stale "Up" apart from
# actually reaching the lease — which is the same probe already needed
# afterward. Only when the probe finds nothing answering (or there is
# nothing to probe at all — a lease from before podenv_lease_port's label
# existed, see that function's own comment) does this script disrupt
# anything, and even then not with `-t 0`: `stop
# -t "$PODENV_STOP_GRACE"` gives a daemon that might be HUNG rather than
# gone a short window to flush before the kill. A container that really is
# already gone returns from `stop` immediately regardless of the timeout
# given, so this costs nothing in the by-far-most-common (already-dead)
# case, and can save data in the hung-not-gone one. Never `podman restart`:
# measured to fail outright on exactly the stale-"Up" state this script
# exists to recover from.
#
# TASK-6 F1 (closing a blind spot, not just documenting it): probe-first
# above used to NOT apply to a --netns host lease at all, because that mode
# publishes no port mapping (`-p` is discarded — see
# patches/paperclip/podenv/podenv's `hport=cport` comment), and `podman
# port` — the only source this script had for "what port do I probe" — has
# structurally nothing to report for it. So every --netns host lease was
# stopped and restarted on EVERY podenv service restart regardless of
# whether it was healthy, and the best this script could do afterward was an
# unread stderr WARNING. Fixed by having cmd_provision record the reachable
# port as a LABEL on the container (opc.podenv.port, both netns modes) and
# reading that instead of `podman port` — see podenv_lease_port below. That
# label does not depend on the container being in any particular runtime
# state or on the netns mode, so a --netns host lease is now probed exactly
# like a --netns pasta one, and the pasta path also stops depending on
# `podman port` output at all. A fallback to `podman port` remains for any
# lease created before this label existed (podenv_lease_port's own comment
# says why); the WARNING further down is now reached only by that leftover
# case, not by every --netns host lease unconditionally.
#
# Never fatal: this is recovery. Every lease is also restartable by hand with
# `podman start <slug>`.
#
# SIBLING BUG, SIBLING FIX — the two must stay in agreement: the exact same
# false-authoritative-state bug (and, in this task's review round, the exact
# same unconditional-disruption regression) existed in `podenv provision`'s
# idempotent re-provision branch (patches/paperclip/podenv/podenv, "container
# exists" branch), and matters MORE there because it is the DOCUMENTED,
# routine path an agent is told to run freely. It is fixed there the same
# shape: probe first (there, with `curl`, classifying its exit code — see
# that file's own comment for why curl and not a bare connect), only
# `stop -t "$PODENV_STOP_GRACE"` then `start` when the probe finds nothing,
# then verify liveness before reporting success, never `podman restart`. The
# two cannot share a file (different images), so if the measured behaviour
# above ever needs revising, revise the comment in both places — this repo
# has been burned by exactly this kind of drift before (see AGENTS.md's note
# on the two `SOUL.md` and two `paperclip-api` SKILL.md copies).
set -u

PODENV_UID="${PODENV_UID:-1000}"
PODENV_GID="${PODENV_GID:-1000}"
# A few seconds, not `-t 0`: see the header comment above (task-5 F1). Only
# reached when the probe below already found nothing answering, so the
# common case (container already dead) returns from `stop` immediately
# regardless of this value — this only spends real time in the rare case
# where the daemon is genuinely hung, which is exactly when it is worth
# spending.
PODENV_STOP_GRACE="${PODENV_STOP_GRACE:-5}"
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
# so tests/podenv.sh can source this script — with NO variable needed, see
# the guard below (task-5 F2) — and call this in isolation against a
# guaranteed-nothing-listening port — a tight loop of single attempts is a
# deterministic regression guard for the exact bug above, where waiting out
# a natural ~1-in-7 flake in the full gate is not. It also doubles as the
# PROBE-FIRST check in the main loop below (task-5 F1): the same "did
# something real answer" question, asked before disrupting anything instead
# of only after.
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

# podenv_lease_port <container> — the port this lease answers on.
#
# TASK-6 F1 (closing a blind spot a reviewer proposed only documenting):
# `podman port` reads a container's published port MAPPING, and a --netns
# host lease has none — cmd_provision discards `-p` entirely for that mode
# (see patches/paperclip/podenv/podenv's `hport=cport` comment). Before this
# function existed, that meant a --netns host lease could never be probed
# here at all: every restart of the podenv service stopped and restarted it
# unconditionally regardless of health, and the best this script could do
# afterward was an unread stderr WARNING that it could not verify — probe-
# first, the whole point of this file, silently did not apply to that mode.
#
# The fix does not try to make `podman port` report something it structurally
# cannot for --netns host. It sidesteps the question: `cmd_provision` already
# records the reachable port as a LABEL on the container itself
# (opc.podenv.port) at create time, for BOTH netns modes — a label this
# script CAN read with `podman inspect`, unlike the registry row (different
# image, no psql client here; see the file header). So: try the label first.
# It works identically for --netns pasta and --netns host, which means the
# pasta path also stops depending on parsing `podman port` output at all —
# one less thing that can change under us.
#
# Fallback to `podman port` only for a lease created before this label
# existed (an already-running container from an older podenv build) — such a
# lease has no opc.podenv.port label to read, so this is the only way to
# probe a pre-existing --netns pasta lease, and for a pre-existing --netns
# host lease it correctly yields nothing (that mode never published a port
# mapping), which the caller treats as "cannot verify" exactly as before this
# fix. `index` rather than `.Config.Labels.opc.podenv.port`: Go's template
# parser would read the dots in the label name as field traversal, the same
# reason the "restore label" check in tests/podenv.sh has to use `index` too.
podenv_lease_port() {
    _plp_c="$1"
    _plp_port="$(podman_r inspect "$_plp_c" \
        --format '{{ index .Config.Labels "opc.podenv.port" }}' 2>/dev/null \
        | tr -d '[:space:]')"
    case "$_plp_port" in
        ''|'<no value>')
            _plp_line="$(podman_r port "$_plp_c" 2>/dev/null | head -1)"
            _plp_port="$(printf '%s' "$_plp_line" | sed -n 's/.*:\([0-9]\+\)[[:space:]]*$/\1/p')"
            ;;
    esac
    printf '%s' "$_plp_port"
}

# Everything below this line is the main restore pass (wait for the socket,
# find labelled leases, probe before disrupting, verify each is genuinely
# alive). Guarded so the SAFE thing — do nothing — is the DEFAULT, and only
# the one real production caller (the entrypoint) has to opt in.
#
# CORRECTED (task-5 F2, measured against myself while verifying the F1 probe
# fix above): the guard used to run the other way around — it took an
# explicit opt-OUT (`PODENV_RESTORE_LIB=1`) to SKIP the main pass, so
# sourcing this file with NO variable set at all ran a full restore pass and
# then hit this script's own `exit 0` at the bottom, which — because the
# file was SOURCED, not executed — silently terminated the CALLING shell
# with no diagnostic whatsoever. Reproduced directly: `. opc-podenv-restore.sh`
# with no leases to restore still printed its one status line and then the
# sourcing shell's own next command never ran, no error, exit status of the
# whole invocation still 0. Forgetting a variable must cost nothing, so this
# is now an explicit opt-IN instead: nothing runs unless
# `PODENV_RESTORE_RUN=1` is set. The entrypoint (invoked as an executed
# script, never sourced) sets it; tests/podenv.sh's "run it directly" checks
# set it too when they specifically want the main pass; every other caller —
# including a plain `. opc-podenv-restore.sh` to reach podenv_probe_answers
# alone — gets a no-op by default. `return`/`exit` split handles both
# calling conventions: sourced, `return 0` hands control back to the caller;
# executed directly (no function/sourcing context to return from), `return`
# itself fails and `exit 0` takes over.
[ "${PODENV_RESTORE_RUN:-0}" = 1 ] || return 0 2>/dev/null || exit 0

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
    # PROBE FIRST (task-5 F1 — see the header comment for the measured
    # regression this replaces): find the lease's reachable port and try it
    # ONCE, before touching the container at all — this succeeding proves the
    # lease never needed disrupting in the first place. Reads the
    # opc.podenv.port LABEL (task-6 F1, podenv_lease_port above), not
    # `podman port` directly: the label is available whether the container is
    # genuinely running, stale-"Up", or truly exited (it is static container
    # config, not runtime state), AND — unlike `podman port` — it exists for
    # a --netns host lease too, which is what makes that mode probeable here
    # at all now.
    _port="$(podenv_lease_port "$_c")"

    if [ -n "$_port" ] && podenv_probe_answers "$_port"; then
        echo "[podenv-restore] $_c already answers on 127.0.0.1:${_port} (exchanged data) — left untouched, no stop/start needed"
        continue
    fi

    # Either there was nothing to probe yet (a genuinely exited container
    # publishes no live port mapping either — the pre-disruption probe above
    # is not expected to succeed for the ordinary boot-time-dead case, only
    # to SKIP disruption for the case that turns out to already be fine), or
    # the probe found nothing answering. Only now is it safe/necessary to
    # disrupt. `stop -t "$PODENV_STOP_GRACE"`, not `-t 0`: harmless on a
    # container that really is already stopped (returns immediately either
    # way); on the stale-"Up" case it is measured to print a loud error
    # ("conmon exited prematurely...") and still land the container in a
    # state `start` can act on — that error is expected and ignored here.
    # Never `podman restart`: measured to fail outright on exactly this
    # state.
    podman_r stop -t "$PODENV_STOP_GRACE" "$_c" >/dev/null 2>&1

    if ! podman_r start "$_c" >/dev/null 2>&1; then
        echo "[podenv-restore] WARNING $_c did not start — investigate: docker compose exec -T -u ${PODENV_UID} -e HOME=/home/podman -e XDG_RUNTIME_DIR=/run/user/${PODENV_UID} podenv podman start $_c" >&2
        continue
    fi

    # The pre-disruption probe above already tried the label AND (for a
    # pre-label lease) the `podman port` fallback via podenv_lease_port. A
    # `run` config could in principle differ from what was read a moment ago
    # — re-check anyway rather than assume, at the cost of one more cheap
    # call.
    if [ -z "$_port" ]; then
        _port="$(podenv_lease_port "$_c")"
    fi
    if [ -z "$_port" ]; then
        # TASK-6 F1: this branch used to be reached by EVERY --netns host
        # lease, unconditionally, because `podman port` structurally cannot
        # report anything for that mode. Now that podenv_lease_port reads the
        # opc.podenv.port label first, a --netns host lease created by the
        # current podenv CLI has a port to probe and takes the normal path
        # above/below instead. This branch is now reached only by a lease
        # that predates the label (an already-running container from an
        # older podenv build, --netns host or otherwise a pasta lease whose
        # `podman port` genuinely has nothing to report) — there really is
        # nothing here this script can probe. Say so rather than silently
        # counting it as restored, and rather than silently claiming it
        # needed restoring at all (it may not have — this is the one
        # remaining case this script cannot tell "was fine" from "was dead"
        # apart on).
        echo "[podenv-restore] WARNING $_c started but has no opc.podenv.port label and publishes no port via 'podman port' either (a lease from before this label existed) — cannot verify liveness by probing; check by hand: docker compose exec -T -u ${PODENV_UID} -e HOME=/home/podman -e XDG_RUNTIME_DIR=/run/user/${PODENV_UID} podenv podman logs $_c" >&2
        continue
    fi

    # `start` returning 0 is not proof of life (see header) — verify by
    # actually reaching the lease's own published port, the same standard
    # opc-prototype-restore.sh holds preview servers to: never trust a
    # daemon's recorded state, probe it.
    #
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
