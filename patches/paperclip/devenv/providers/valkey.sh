#!/bin/sh
# devenv valkey provider.
#
# Unlike postgres, a valkey tenant is identified by a NUMBER, not a name —
# that asymmetry is the whole reason the registry exists. The db id is
# allocated by devenv_valkey_db_alloc() (registry-side, UNIQUE-constrained)
# and then hidden inside VALKEY_URL's path, so callers never handle it.
#
# Isolation is the 9.1+ `db=<dbid>` ACL op, enforced in ACLSelectorCanAccessDb():
# without the ALLDBS flag the selector's db intset is checked on every command.

valkey_probe() {
    devenv_valkey_admin PING 2>/dev/null | grep -q PONG
}

valkey_provision() {
    _vkp_key="$1"; _vkp_slug="$2"

    _vkp_db="$(devenv_valkey_db_alloc "$_vkp_key")" || return $?
    _vkp_pw="$(devenv_derive_password "$_vkp_key" valkey)"

    # resetdbs clears any inherited grant before db= narrows it, so a re-run
    # never widens an existing user's reach.
    devenv_valkey_admin ACL SETUSER "$_vkp_slug" \
        on ">${_vkp_pw}" resetdbs "db=${_vkp_db}" "~*" +@all -@dangerous >/dev/null

    printf 'VALKEY_URL=redis://%s:%s@%s:%s/%s\n' \
        "$_vkp_slug" "$_vkp_pw" "$DEVENV_VALKEY_HOST" "$DEVENV_VALKEY_PORT" "$_vkp_db"
}

valkey_release() {
    _vkr_slug="$2"
    devenv_valkey_admin ACL DELUSER "$_vkr_slug" >/dev/null 2>&1 || true
    # The db id is freed by the registry row deletion in the CLI; data left in
    # that numbered db would leak into the next tenant, so flush it here.
    _vkr_db="$(devenv_registry_get "$1" valkey_db)"
    if [ -n "$_vkr_db" ]; then
        devenv_valkey_admin -n "$_vkr_db" FLUSHDB >/dev/null 2>&1 || true
    fi
}
