#!/bin/sh
# opc-devenv-seed.sh — source from the paperclip entrypoint.
#
# Creates the devenv control database and applies its schema (table + the
# devenv_usage view) on every boot. Idempotent: CREATE DATABASE is guarded,
# the schema uses IF NOT EXISTS / CREATE OR REPLACE.
#
# Runs here rather than as its own compose one-shot because paperclip already
# depends_on devenv-pg being healthy, and the SQL is baked into this image
# alongside the CLI that consumes it.
#
# Never fatal: devenv is an optional lane. An unreachable backend means
# `devenv` reports exit code 4 when used, not that paperclip fails to start.
#
# Split into two entry points on purpose. `opc_devenv_seed_schema` is the
# database+schema half and is ALSO called by the `devenv-expert-leases`
# compose one-shot (same image, same file) before it provisions: that one-shot
# used to depend on this entrypoint having already run, which on a clean
# machine it has not — the nix/mise/gh/claude seeds above the call site take
# minutes on an empty *-mise volume, so the one-shot raced them and lost,
# every time, silently and permanently (it exits 0 by design, so no later
# `docker compose up` re-runs it). Making the schema the one-shot's own
# responsibility removes the race without making the gateway wait on
# paperclip's health. Both callers run the same idempotent SQL.
opc_devenv_seed() {
    opc_devenv_seed_schema

    # `|| true` is load-bearing, not decoration: the entrypoint runs under
    # `set -e` and this whole file's contract is "never fatal — devenv is an
    # optional lane". A warning-only diagnostic must not be able to crash-loop
    # paperclip, which is exactly what happened when the check below had a bug.
    #
    # Not part of opc_devenv_seed_schema: the port pool is read from the
    # paperclip container's own DEVENV_HTTP_* env and its own network
    # namespace, neither of which the one-shot has.
    opc_devenv_check_port_pool || true
}

opc_devenv_seed_schema() {
    _dv_host="${DEVENV_PG_HOST:-devenv-pg}"
    _dv_port="${DEVENV_PG_PORT:-5432}"
    _dv_user="${DEVENV_PG_ADMIN_USER:-postgres}"
    _dv_db="${DEVENV_CONTROL_DB:-devenv_control}"
    _dv_sql="${DEVENV_LIB:-/usr/local/lib/devenv}/bootstrap.sql"

    if [ -z "${DEVENV_PG_ADMIN_PASSWORD:-}" ]; then
        echo "[devenv-seed] DEVENV_PG_ADMIN_PASSWORD unset — skipping (devenv disabled)" >&2
        return 0
    fi

    _dv_psql() {
        # client_min_messages=warning: the schema is re-applied every boot, so
        # its IF NOT EXISTS / ADD COLUMN IF NOT EXISTS statements emit a NOTICE
        # per object on every single start. Stdout is already discarded; these
        # go to stderr and would otherwise bury real warnings.
        PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" \
        PGOPTIONS='-c client_min_messages=warning' psql \
            -h "$_dv_host" -p "$_dv_port" -U "$_dv_user" -q "$@"
    }

    if ! _dv_psql -d postgres -c 'SELECT 1' >/dev/null 2>&1; then
        echo "[devenv-seed] $_dv_host:$_dv_port unreachable — skipping" >&2
        return 0
    fi

    # `|| re-check` rather than `|| give up`: this function now has two
    # callers (the entrypoint and the devenv-expert-leases one-shot) and
    # nothing orders them, so on a warm boot both can reach this point at the
    # same instant. The loser of a CREATE DATABASE race gets "already exists",
    # which is success as far as the caller's goal is concerned — treat it as
    # such by asking pg again instead of reporting a failure that isn't one.
    if ! _dv_psql -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname = '$_dv_db'" | grep -q 1; then
        if ! _dv_psql -d postgres -c "CREATE DATABASE $_dv_db" >/dev/null 2>&1; then
            if ! _dv_psql -d postgres -tAc \
                "SELECT 1 FROM pg_database WHERE datname = '$_dv_db'" | grep -q 1; then
                echo "[devenv-seed] CREATE DATABASE $_dv_db failed" >&2
                return 0
            fi
        fi
    fi

    # Tenant roles must not read the registry: PUBLIC gets CONNECT on new
    # databases by default, so revoke it explicitly.
    _dv_psql -d postgres -c "REVOKE CONNECT ON DATABASE $_dv_db FROM PUBLIC" >/dev/null 2>&1 || true

    # Same two-writer reasoning as the CREATE DATABASE above: the SQL is
    # idempotent but concurrent `CREATE TABLE IF NOT EXISTS` / `DROP VIEW` can
    # still collide on pg's catalog. One retry turns that into a non-event.
    if _dv_psql -d "$_dv_db" -v ON_ERROR_STOP=1 -f "$_dv_sql" >/dev/null 2>&1 \
        || _dv_psql -d "$_dv_db" -v ON_ERROR_STOP=1 -f "$_dv_sql" >/dev/null; then
        echo "[devenv-seed] $_dv_db schema ready (devenv_tenant + devenv_usage)"
    else
        echo "[devenv-seed] schema apply failed — devenv will not work" >&2
        return 0
    fi
}

# Two ways the preview-port pool gets silently misconfigured. Both are warnings
# only: a bad pool must not stop the stack from coming up, and neither symptom
# appears until someone actually leases a port.
opc_devenv_check_port_pool() {
    _dv_base="${DEVENV_HTTP_PORT_BASE:-21000}"
    _dv_count="${DEVENV_HTTP_PORT_COUNT:-16}"
    _dv_end="${DEVENV_HTTP_PORT_RANGE_END:-}"

    # Validate BEFORE the arithmetic, not after: `$((...))` on a non-numeric
    # operand is an EXPANSION error under dash, not a command that returns
    # nonzero — it aborts the shell outright, and the caller's `|| true`
    # does NOT save it (the crash happens before there is a command to
    # attach `||` to). A typo'd DEVENV_HTTP_PORT_BASE/COUNT in `.env` used to
    # crash-loop paperclip's entrypoint this way. Warn and skip instead —
    # this check is a warning-only nicety, not load-bearing.
    case "$_dv_base" in
        ''|*[!0-9]*)
            echo "[devenv-seed] WARNING DEVENV_HTTP_PORT_BASE='$_dv_base' is not a positive integer — skipping the port-pool check" >&2
            return 0 ;;
    esac
    case "$_dv_count" in
        ''|*[!0-9]*)
            echo "[devenv-seed] WARNING DEVENV_HTTP_PORT_COUNT='$_dv_count' is not a positive integer — skipping the port-pool check" >&2
            return 0 ;;
    esac
    _dv_last=$((_dv_base + _dv_count - 1))

    # (1) RANGE_END out of sync with BASE + COUNT. compose cannot do
    # arithmetic, so the pool bounds are stated twice — once for the CLI to
    # allocate from, once for compose to publish. Disagreement means devenv
    # hands out ports docker never published: the URL simply does not connect,
    # with nothing anywhere saying why.
    if [ -n "$_dv_end" ] && [ "$_dv_end" -ne "$_dv_last" ]; then
        echo "[devenv-seed] WARNING DEVENV_HTTP_PORT_RANGE_END=$_dv_end but BASE+COUNT-1=$_dv_last." >&2
        echo "[devenv-seed]   devenv will lease ports docker has not published; those previews will not open." >&2
        echo "[devenv-seed]   Fix .env so RANGE_END = BASE + COUNT - 1, then recreate the paperclip container." >&2
    fi

    # (2) Pool overlapping the kernel's ephemeral range. Read from INSIDE this
    # container on purpose: the collision is with bind(port 0) calls made here
    # (paperclip's allocatePort() for `port: {type: auto}` services), and a
    # container has its own network namespace, so the host's value is not
    # necessarily this one.
    if [ -r /proc/sys/net/ipv4/ip_local_port_range ]; then
        # NOT `read a b < /proc/...`: procfs files report st_size 0, and dash's
        # read builtin mishandles that — it returns 1 having consumed a single
        # byte ("32768\t60999" yields a="3"). Under `set -e` that killed the
        # entrypoint. `cat` in a command substitution has no such problem.
        # (bash's read happens to work here, but /bin/sh in this image is dash.)
        set -- $(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null)
        _dv_eph_lo="${1:-}"; _dv_eph_hi="${2:-}"
    fi
    if [ -n "${_dv_eph_lo:-}" ] && [ -n "${_dv_eph_hi:-}" ]; then
        if [ "$_dv_base" -le "$_dv_eph_hi" ] && [ "$_dv_last" -ge "$_dv_eph_lo" ]; then
            echo "[devenv-seed] WARNING preview port pool ${_dv_base}-${_dv_last} overlaps the ephemeral range ${_dv_eph_lo}-${_dv_eph_hi}." >&2
            echo "[devenv-seed]   The kernel hands those out at random to any bind(0), so a leased port can be" >&2
            echo "[devenv-seed]   stolen while its server is stopped and the tenant then fails to start." >&2
            echo "[devenv-seed]   Move DEVENV_HTTP_PORT_BASE below ${_dv_eph_lo}." >&2
        fi
    fi
}
