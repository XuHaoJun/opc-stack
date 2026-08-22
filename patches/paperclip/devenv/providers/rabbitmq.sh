#!/bin/sh
# devenv RabbitMQ provider.
#
# Contract:
#   rabbitmq_provision <key> <slug>   idempotent create, prints KEY=VALUE lines
#   rabbitmq_release   <key> <slug>   idempotent remove
#   rabbitmq_probe                    backend reachability
#
# Isolation is logical: one vhost and one untagged user per lease. RabbitMQ
# shares CPU, memory, disk, and its Erlang node across vhosts; per-vhost limits
# are guardrails, not physical resource isolation.

DEVENV_RABBITMQ_HOST="${DEVENV_RABBITMQ_HOST:-devenv-rabbitmq}"
DEVENV_RABBITMQ_PORT="${DEVENV_RABBITMQ_PORT:-5672}"
DEVENV_RABBITMQ_API_PORT="${DEVENV_RABBITMQ_API_PORT:-15672}"
DEVENV_RABBITMQ_ADMIN_USER="${DEVENV_RABBITMQ_ADMIN_USER:-devenv-admin}"
DEVENV_RABBITMQ_ADMIN_PASSWORD="${DEVENV_RABBITMQ_ADMIN_PASSWORD:-devenv-rabbitmq}"
DEVENV_RABBITMQ_MAX_CONNECTIONS="${DEVENV_RABBITMQ_MAX_CONNECTIONS:-32}"
DEVENV_RABBITMQ_MAX_QUEUES="${DEVENV_RABBITMQ_MAX_QUEUES:-256}"

rabbitmq_api() {
    _rma_method="$1"; _rma_path="$2"
    if [ "$#" -eq 3 ]; then
        curl --connect-timeout 3 --max-time 10 -fsS \
            -u "$DEVENV_RABBITMQ_ADMIN_USER:$DEVENV_RABBITMQ_ADMIN_PASSWORD" \
            -H 'content-type: application/json' -X "$_rma_method" \
            --data "$3" \
            "http://$DEVENV_RABBITMQ_HOST:$DEVENV_RABBITMQ_API_PORT/api/$_rma_path"
    else
        curl --connect-timeout 3 --max-time 10 -fsS \
            -u "$DEVENV_RABBITMQ_ADMIN_USER:$DEVENV_RABBITMQ_ADMIN_PASSWORD" \
            -X "$_rma_method" \
            "http://$DEVENV_RABBITMQ_HOST:$DEVENV_RABBITMQ_API_PORT/api/$_rma_path"
    fi
}

rabbitmq_delete_if_present() {
    _rmd_path="$1"
    _rmd_code="$(curl --connect-timeout 3 --max-time 10 -sS \
        -u "$DEVENV_RABBITMQ_ADMIN_USER:$DEVENV_RABBITMQ_ADMIN_PASSWORD" \
        -o /dev/null -w '%{http_code}' -X DELETE \
        "http://$DEVENV_RABBITMQ_HOST:$DEVENV_RABBITMQ_API_PORT/api/$_rmd_path")" \
        || return 1
    case "$_rmd_code" in 204|404) return 0 ;; *) return 1 ;; esac
}

rabbitmq_probe() {
    rabbitmq_api GET health/checks/ready-to-serve-clients >/dev/null 2>&1
}

rabbitmq_provision_fail() {
    _rmpf_key="$1"; _rmpf_slug="$2"; _rmpf_existing="$3"
    # A new provider is not yet in the registry, so cmd_provision's generic
    # rollback cannot discover it. Remove partial broker state ourselves. An
    # existing lease is different: never destroy live resources because one
    # reconciliation call failed midway.
    if [ -z "$_rmpf_existing" ]; then
        rabbitmq_release "$_rmpf_key" "$_rmpf_slug" >/dev/null 2>&1 || true
    fi
    die "RabbitMQ reconciliation failed for '$_rmpf_key'" 4
}

rabbitmq_provision() {
    _rmp_key="$1"; _rmp_slug="$2"
    _rmp_existing="$(devenv_registry_get "$_rmp_key" rabbitmq_vhost)"
    _rmp_pw="$(devenv_derive_password "$_rmp_key" rabbitmq)"
    _rmp_user="$_rmp_slug"
    _rmp_vhost="$_rmp_slug"
    _rmp_user_uri="$(jq -nr --arg v "$_rmp_user" '$v|@uri')"
    _rmp_vhost_uri="$(jq -nr --arg v "$_rmp_vhost" '$v|@uri')"

    _rmp_user_body="$(jq -nc --arg password "$_rmp_pw" \
        '{password:$password,tags:""}')"
    rabbitmq_api PUT "users/$_rmp_user_uri" "$_rmp_user_body" >/dev/null \
        || rabbitmq_provision_fail "$_rmp_key" "$_rmp_slug" "$_rmp_existing"
    rabbitmq_api PUT "vhosts/$_rmp_vhost_uri" '{}' >/dev/null \
        || rabbitmq_provision_fail "$_rmp_key" "$_rmp_slug" "$_rmp_existing"
    rabbitmq_api PUT "permissions/$_rmp_vhost_uri/$_rmp_user_uri" \
        '{"configure":".*","write":".*","read":".*"}' >/dev/null \
        || rabbitmq_provision_fail "$_rmp_key" "$_rmp_slug" "$_rmp_existing"
    rabbitmq_api PUT "vhost-limits/$_rmp_vhost_uri/max-connections" \
        "$(jq -nc --argjson value "$DEVENV_RABBITMQ_MAX_CONNECTIONS" '{value:$value}')" >/dev/null \
        || rabbitmq_provision_fail "$_rmp_key" "$_rmp_slug" "$_rmp_existing"
    rabbitmq_api PUT "vhost-limits/$_rmp_vhost_uri/max-queues" \
        "$(jq -nc --argjson value "$DEVENV_RABBITMQ_MAX_QUEUES" '{value:$value}')" >/dev/null \
        || rabbitmq_provision_fail "$_rmp_key" "$_rmp_slug" "$_rmp_existing"

    printf 'AMQP_URL=amqp://%s:%s@%s:%s/%s\n' \
        "$_rmp_user" "$_rmp_pw" "$DEVENV_RABBITMQ_HOST" "$DEVENV_RABBITMQ_PORT" "$_rmp_vhost"
}

rabbitmq_release() {
    _rmr_slug="$2"
    _rmr_user_uri="$(jq -nr --arg v "$_rmr_slug" '$v|@uri')" || return 1
    _rmr_vhost_uri="$_rmr_user_uri"

    # Deleting the vhost removes its queues, exchanges, messages, bindings,
    # policies, limits, and permissions. Delete the now-unreferenced user last.
    rabbitmq_delete_if_present "vhosts/$_rmr_vhost_uri" || return 1
    rabbitmq_delete_if_present "users/$_rmr_user_uri" || return 1
}
