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
opc_devenv_seed() {
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
        PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" psql \
            -h "$_dv_host" -p "$_dv_port" -U "$_dv_user" -q "$@"
    }

    if ! _dv_psql -d postgres -c 'SELECT 1' >/dev/null 2>&1; then
        echo "[devenv-seed] $_dv_host:$_dv_port unreachable — skipping" >&2
        return 0
    fi

    if ! _dv_psql -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname = '$_dv_db'" | grep -q 1; then
        _dv_psql -d postgres -c "CREATE DATABASE $_dv_db" >/dev/null || {
            echo "[devenv-seed] CREATE DATABASE $_dv_db failed" >&2; return 0; }
    fi

    # Tenant roles must not read the registry: PUBLIC gets CONNECT on new
    # databases by default, so revoke it explicitly.
    _dv_psql -d postgres -c "REVOKE CONNECT ON DATABASE $_dv_db FROM PUBLIC" >/dev/null 2>&1 || true

    if _dv_psql -d "$_dv_db" -v ON_ERROR_STOP=1 -f "$_dv_sql" >/dev/null; then
        echo "[devenv-seed] $_dv_db schema ready (devenv_tenant + devenv_usage)"
    else
        echo "[devenv-seed] schema apply failed — devenv will not work" >&2
    fi
}
