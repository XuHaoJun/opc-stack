#!/bin/sh
# devenv postgres provider.
#
# Contract (see the spec's "Resource provider 契約"):
#   postgres_provision <key> <slug>   idempotent create, prints KEY=VALUE lines
#   postgres_release   <key> <slug>   idempotent remove
#   postgres_probe                    backend reachability
#
# Tenant identity is the NAME (devenv_<slug>), so no allocation is needed —
# unlike valkey, which is numbered.

postgres_probe() {
    devenv_psql_admin -c 'SELECT 1' >/dev/null 2>&1
}

postgres_provision() {
    _pgp_key="$1"; _pgp_slug="$2"

    # Passwords are DERIVED, not stored: provision must be idempotent (a
    # re-run has to hand back the same credential a stale .env already holds),
    # and derivation gets that without keeping plaintext secrets in a table.
    _pgp_pw="$(devenv_derive_password "$_pgp_key" postgres)"

    devenv_psql_admin -v ON_ERROR_STOP=1 <<SQL >/dev/null
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${_pgp_slug}') THEN
    CREATE ROLE ${_pgp_slug} LOGIN PASSWORD '${_pgp_pw}';
  ELSE
    ALTER ROLE ${_pgp_slug} LOGIN PASSWORD '${_pgp_pw}';
  END IF;
END
\$\$;
SQL

    # CREATE DATABASE cannot run inside a transaction/DO block.
    if ! devenv_psql_admin -tAc \
        "SELECT 1 FROM pg_database WHERE datname = '${_pgp_slug}'" | grep -q 1; then
        devenv_psql_admin -v ON_ERROR_STOP=1 \
            -c "CREATE DATABASE ${_pgp_slug} OWNER ${_pgp_slug}" >/dev/null
    fi

    devenv_psql_admin -v ON_ERROR_STOP=1 \
        -c "REVOKE CONNECT ON DATABASE ${_pgp_slug} FROM PUBLIC" >/dev/null
    devenv_psql -d "$_pgp_slug" -v ON_ERROR_STOP=1 \
        -c "CREATE EXTENSION IF NOT EXISTS vector" >/dev/null

    printf 'DATABASE_URL=postgres://%s:%s@%s:%s/%s\n' \
        "$_pgp_slug" "$_pgp_pw" "$DEVENV_PG_HOST" "$DEVENV_PG_PORT" "$_pgp_slug"
}

postgres_release() {
    _pgr_slug="$2"
    # Terminate stragglers first — DROP DATABASE fails while sessions remain.
    devenv_psql_admin -v ON_ERROR_STOP=1 -c \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${_pgr_slug}'" \
        >/dev/null
    devenv_psql_admin -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS ${_pgr_slug}" >/dev/null
    devenv_psql_admin -v ON_ERROR_STOP=1 -c "DROP ROLE IF EXISTS ${_pgr_slug}" >/dev/null
}
