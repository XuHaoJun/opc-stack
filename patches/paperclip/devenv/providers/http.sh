#!/bin/sh
# devenv http provider — preview ports for prototype dev servers.
#
# Contract (see the spec's "Resource provider 契約"):
#   http_provision <key> <slug>   idempotent allocate, prints KEY=VALUE lines
#   http_release   <key> <slug>   idempotent remove
#   http_probe                    backend reachability
#
# Unlike postgres (named) and valkey (a single number), a tenant here holds a
# CONTIGUOUS RANGE of ports. That difference drives everything below.
#
# Why the range is static and lives in docker-compose.yml: docker fixes a
# container's published ports at CREATE time — there is no way to add a
# mapping to a running container. Only the allocation WITHIN the range is
# dynamic. Changing the range size means recreating the paperclip container.
#
# Why the base sits below 32768: that is the kernel's ephemeral range (see
# /proc/sys/net/ipv4/ip_local_port_range), from which any bind(port 0) — such
# as paperclip's own allocatePort() for `port: {type: auto}` services — is
# served at random. A lease inside that range can be handed out by the kernel
# to something else while the tenant's server happens to be stopped, and the
# tenant then fails to start. Scanning for "free" ports cannot fix this: the
# conflict is in the future. Below 32768 the kernel never assigns on its own.

DEVENV_HTTP_PORT_BASE="${DEVENV_HTTP_PORT_BASE:-21000}"
DEVENV_HTTP_PORT_COUNT="${DEVENV_HTTP_PORT_COUNT:-16}"
# Host part of DEV_URL — the address a BROWSER will use, which is not
# necessarily how the container sees itself.
#
# Default: the host from PAPERCLIP_PUBLIC_URL. The preview link is opened from
# the Paperclip board, so the two are reachable from the same place by
# definition; deriving it means the stack's address is configured once instead
# of being repeated in a second variable that can silently disagree (a
# disagreement whose only symptom is a link that does not open).
if [ -z "${DEVENV_HTTP_PUBLIC_HOST:-}" ]; then
    DEVENV_HTTP_PUBLIC_HOST="$(printf '%s' "${PAPERCLIP_PUBLIC_URL:-}" \
        | sed -n 's|^[a-zA-Z][a-zA-Z0-9+.-]*://\([^/:]*\).*|\1|p')"
    DEVENV_HTTP_PUBLIC_HOST="${DEVENV_HTTP_PUBLIC_HOST:-localhost}"
fi

# The registry IS the backend — there is no separate service to reach.
http_probe() {
    postgres_probe
}

# Smallest start p with [p, p+n) inside the range and disjoint from every
# existing lease.
#
# LOCK TABLE, not SELECT ... FOR UPDATE: row locks cannot stop a CONCURRENT
# INSERT of a new overlapping lease (a phantom), which is exactly the race
# here. provision is rare and the table is tiny, so the coarse lock is free.
# It is taken inside psql's implicit single-statement-string transaction, so
# it is released when the command returns either way.
devenv_http_port_alloc() {
    _hpa_key="$1"; _hpa_n="$2"
    _hpa_max_start=$((DEVENV_HTTP_PORT_BASE + DEVENV_HTTP_PORT_COUNT - _hpa_n))
    [ "$_hpa_max_start" -ge "$DEVENV_HTTP_PORT_BASE" ] \
        || die "cannot lease $_hpa_n contiguous ports: the pool is only $DEVENV_HTTP_PORT_COUNT wide (DEVENV_HTTP_PORT_COUNT)" 3

    _hpa_out="$(devenv_psql_control -v ON_ERROR_STOP=1 -tAc "
        LOCK TABLE devenv_tenant IN EXCLUSIVE MODE;
        WITH free AS (
            SELECT p FROM generate_series($DEVENV_HTTP_PORT_BASE, $_hpa_max_start) AS p
            WHERE NOT EXISTS (
                SELECT 1 FROM devenv_tenant t
                WHERE t.http_port_start IS NOT NULL
                  AND t.http_port_start < p + $_hpa_n
                  AND p < t.http_port_start + t.http_port_count
            )
            ORDER BY p LIMIT 1
        )
        UPDATE devenv_tenant t
           SET http_port_start = free.p, http_port_count = $_hpa_n
          FROM free
         WHERE t.key = '$_hpa_key'
     RETURNING t.http_port_start;")"
    _hpa_out="$(echo "$_hpa_out" | tr -d '[:space:]')"
    [ -n "$_hpa_out" ] \
        || die "no free block of $_hpa_n port(s) in ${DEVENV_HTTP_PORT_BASE}..$((DEVENV_HTTP_PORT_BASE + DEVENV_HTTP_PORT_COUNT - 1)) — run 'devenv list' and release one" 3
    echo "$_hpa_out"
}

http_provision() {
    _hp_key="$1"
    _hp_n="${DEVENV_HTTP_COUNT:-1}"

    _hp_start="$(devenv_registry_get "$_hp_key" http_port_start)"
    if [ -n "$_hp_start" ]; then
        # Idempotent re-run must hand back the SAME ports a stale .env holds.
        _hp_have="$(devenv_registry_get "$_hp_key" http_port_count)"
        if [ "$_hp_have" != "$_hp_n" ]; then
            die "'$_hp_key' already holds $_hp_have port(s); resizing would move the block and invalidate the issued .env — 'devenv release $_hp_key' first" 2
        fi
    else
        _hp_start="$(devenv_http_port_alloc "$_hp_key" "$_hp_n")" || return $?
    fi

    printf 'DEV_PORT=%s\n' "$_hp_start"
    _hp_i=1
    while [ "$_hp_i" -lt "$_hp_n" ]; do
        printf 'DEV_PORT_%s=%s\n' "$((_hp_i + 1))" "$((_hp_start + _hp_i))"
        _hp_i=$((_hp_i + 1))
    done
    printf 'DEV_URL=http://%s:%s\n' "$DEVENV_HTTP_PUBLIC_HOST" "$_hp_start"
    # Bare host, no scheme or port. Dev servers increasingly refuse requests
    # whose Host/Origin is not localhost and need it listed explicitly —
    # Next.js 16 `allowedDevOrigins` (403s even a SAME-origin request when the
    # host is an IP), Vite `server.allowedHosts`. Handing over the host as its
    # own variable means those configs can be written once and stay correct
    # wherever the preview is published.
    printf 'DEV_HOST=%s\n' "$DEVENV_HTTP_PUBLIC_HOST"

    # The single most important line this provider emits.
    #
    # vite/next/nuxt bind loopback by default. Docker's published-port traffic
    # arrives on the container's eth0, so a loopback-bound dev server is
    # unreachable from the host — while paperclip's readiness probe, which runs
    # INSIDE the container against 127.0.0.1, still passes. The board shows a
    # healthy green URL that does not open. Making the correct bind the default
    # is the provider's job; documenting it and hoping is not.
    printf 'HOST=0.0.0.0\n'
}

http_release() {
    # Nothing to clean up outside the registry: the CLI's DELETE of the tenant
    # row frees the block. Unlike valkey there is no server-side state (no
    # data to flush) and unlike postgres no object to drop.
    #
    # A service still LISTENING on the freed port is a real hazard — the next
    # tenant would fail to start — but stopping it needs paperclip context the
    # release path usually lacks. The CLI handles that and warns; see cmd_release.
    :
}
