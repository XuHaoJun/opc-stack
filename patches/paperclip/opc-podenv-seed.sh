#!/bin/sh
# opc-podenv-seed.sh — source from the paperclip entrypoint.
#
# Applies the podenv control schema (podenv_lease + podenv_usage) into the
# devenv control database on every boot, and warns about a misconfigured port
# pool. Idempotent.
#
# Never fatal, for the same reason opc-devenv-seed.sh is not: podenv is an
# optional lane. An unreachable backend means the CLI reports exit 4 when used,
# not that paperclip fails to start. paperclip has no depends_on edge to the
# podenv service either — invariant 8's lesson, where `hermes` waiting on a
# one-shot meant any non-zero exit took down the whole agent runtime.
opc_podenv_seed() {
    opc_podenv_seed_schema || true
    opc_podenv_check_port_pool || true
}

opc_podenv_seed_schema() {
    _pe_host="${DEVENV_PG_HOST:-devenv-pg}"
    _pe_port="${DEVENV_PG_PORT:-5432}"
    _pe_user="${DEVENV_PG_ADMIN_USER:-postgres}"
    _pe_db="${DEVENV_CONTROL_DB:-devenv_control}"
    _pe_sql="${PODENV_LIB:-/usr/local/lib/podenv}/bootstrap.sql"

    if [ -z "${DEVENV_PG_ADMIN_PASSWORD:-}" ]; then
        echo "[podenv-seed] DEVENV_PG_ADMIN_PASSWORD unset — skipping (podenv disabled)" >&2
        return 0
    fi
    # The control DATABASE is created by opc-devenv-seed.sh, which the
    # entrypoint sources before this one. Do not create it here: two creators
    # of one database is exactly the kind of second writer this repo's PRD
    # forbids, and the devenv seed already handles the concurrent-create race.
    if ! PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" psql -h "$_pe_host" -p "$_pe_port" \
            -U "$_pe_user" -d "$_pe_db" -tAc 'SELECT 1' >/dev/null 2>&1; then
        echo "[podenv-seed] $_pe_db on $_pe_host:$_pe_port unreachable — skipping" >&2
        return 0
    fi
    if PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" PGOPTIONS='-c client_min_messages=warning' \
        psql -h "$_pe_host" -p "$_pe_port" -U "$_pe_user" -d "$_pe_db" \
             -q -v ON_ERROR_STOP=1 -f "$_pe_sql" >/dev/null 2>&1; then
        echo "[podenv-seed] $_pe_db schema ready (podenv_lease + podenv_usage)"
    else
        echo "[podenv-seed] schema apply failed — podenv will not work" >&2
    fi
    return 0
}

# The pool bounds are stated twice — once here for the CLI to allocate from,
# once in compose's `ports:` to publish. compose cannot do arithmetic, so
# disagreement is possible and its symptom is invisible: podenv hands out a
# port docker never published, and the operator's client simply cannot connect
# with nothing anywhere saying why. Same hazard as DEVENV_HTTP_PORT_RANGE_END.
opc_podenv_check_port_pool() {
    _pe_base="${PODENV_PORT_BASE:-23000}"
    _pe_count="${PODENV_PORT_COUNT:-16}"
    _pe_end="${PODENV_PORT_RANGE_END:-}"
    _pe_last=$((_pe_base + _pe_count - 1))

    if [ -n "$_pe_end" ] && [ "$_pe_end" -ne "$_pe_last" ]; then
        echo "[podenv-seed] WARNING PODENV_PORT_RANGE_END=$_pe_end but BASE+COUNT-1=$_pe_last." >&2
        echo "[podenv-seed]   podenv will lease ports docker has not published; clients will not connect." >&2
        echo "[podenv-seed]   Fix .env so RANGE_END = BASE + COUNT - 1, then recreate the podenv container." >&2
    fi

    # Read from INSIDE this container: the collision is with bind(0) calls made
    # here, and a container has its own network namespace. NOT `read a b <
    # /proc/...` — procfs reports st_size 0 and dash's read mishandles that
    # (see the same comment in opc-devenv-seed.sh, where it killed the
    # entrypoint under set -e).
    if [ -r /proc/sys/net/ipv4/ip_local_port_range ]; then
        set -- $(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null)
        _pe_lo="${1:-}"; _pe_hi="${2:-}"
    fi
    if [ -n "${_pe_lo:-}" ] && [ -n "${_pe_hi:-}" ]; then
        if [ "$_pe_base" -le "$_pe_hi" ] && [ "$_pe_last" -ge "$_pe_lo" ]; then
            echo "[podenv-seed] WARNING podenv port pool ${_pe_base}-${_pe_last} overlaps the ephemeral range ${_pe_lo}-${_pe_hi}." >&2
            echo "[podenv-seed]   Move PODENV_PORT_BASE below ${_pe_lo}." >&2
        fi
    fi
}
