#!/bin/sh
# shared.sh — the truths `devenv` and `podenv` must not disagree about.
#
# Sourced by BOTH CLIs. This file exists because this repo has been burned at
# least three times by the same rule living in two places (two copies of the
# paperclip-api SKILL.md, two copies of SOUL.md, the nix seed tool list) —
# scripts/prepare.sh's drift checks are the scar tissue. Both CLIs ship in the
# same image, so sharing a file removes the drift class entirely instead of
# adding a fourth check for it.
#
# NOT here: psql connection plumbing. Each CLI keeps its own, because if that
# drifts the failure is loud (a connection error), whereas a drifted reserved
# name is silent (two tools writing the same .env key).

# Every .env variable name devenv owns. podenv REFUSES to write any of these,
# which is what makes "postgres from devenv + Milvus from podenv" the only
# possible shape rather than merely the recommended one.
#
# Derived by reading providers/*.sh: postgres.sh -> DATABASE_URL,
# valkey.sh -> VALKEY_URL, http.sh -> DEV_PORT, DEV_PORT_<n>, DEV_URL,
# DEV_HOST, HOST, s3.sh -> AWS_ENDPOINT_URL, AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY, AWS_REGION, S3_BUCKET, S3_FORCE_PATH_STYLE.
# DEV_PORT_ is a PREFIX rule, so callers must treat it as one
# (see devenv_env_name_reserved below).
devenv_reserved_env_names() {
    cat <<'NAMES'
DATABASE_URL
VALKEY_URL
DEV_PORT
DEV_URL
DEV_HOST
HOST
AWS_ENDPOINT_URL
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_REGION
S3_BUCKET
S3_FORCE_PATH_STYLE
NAMES
}

# True when $1 is a name devenv owns, including the DEV_PORT_<n> family.
devenv_env_name_reserved() {
    devenv_reserved_env_names | grep -qx "$1" && return 0
    case "$1" in DEV_PORT_[0-9]*) return 0 ;; esac
    return 1
}

# Image families devenv already serves, as `family=provider` lines. podenv's
# route gate reads this so "devenv already provides it, so prefer devenv" is a
# mechanism and not just prose in a skill.
# Derived by reading providers/*.sh: postgres.sh, valkey.sh, http.sh, s3.sh.
devenv_provider_image_families() {
    cat <<'FAMILIES'
postgres=postgres
pgvector=postgres
valkey=valkey
redis=valkey
s3=s3
minio=s3
rustfs=s3
FAMILIES
}

# Renamings of the SAME software devenv serves, published under a different
# repo name — NOT a general alias mechanism. `postgresql` is Bitnami's (and
# others') name for the exact software devenv-pg is; the caller must lowercase
# and strip registry/tag/digest before calling this (see podenv's route gate),
# this only resolves the name itself. valkey/redis need no entry here: once
# case is normalised, Bitnami's `bitnami/valkey` and `bitnami/redis` already
# collapse to the same family strings `devenv_provider_image_families` uses.
#
# Do NOT add MariaDB, MySQL, Milvus, or anything else devenv does not serve —
# gating software podenv is meant to carry would be a bug, not thoroughness.
devenv_image_family_alias() {
    case "$1" in
        postgresql) echo postgres ;;
        *)          echo "$1" ;;
    esac
}

# Exact-match lookup into devenv_provider_image_families's `family=provider`
# lines. A STRING comparison, not a sed/grep pattern match: the family name
# comes from an --image the caller chose, and interpolating it into a sed
# PATTERN (as podenv briefly did) puts it in regex position, where `.` is a
# wildcard — a family literally named `p.stgres` would then false-positive
# against the `postgres=postgres` line. Prints the provider on a match,
# nothing on a miss (never dies — callers decide what a miss means).
devenv_provider_for_family() {
    _dpf_fam="$1"
    devenv_provider_image_families | while IFS='=' read -r _dpf_f _dpf_p; do
        if [ "$_dpf_f" = "$_dpf_fam" ]; then
            printf '%s\n' "$_dpf_p"
            break
        fi
    done
}

# Derived, not stored: a re-run must hand back the credential a stale .env
# already holds, and derivation achieves that without plaintext secrets at rest.
#
# Calls die() rather than returning a bare status: both CLIs source this file
# AFTER their own die()/note() are defined (see the source lines in `devenv`
# and `podenv`), specifically so this can use exit 4 — "backend unreachable /
# cannot proceed" — which is the code this failure had before the function
# moved here, and the only one the exit-code table documents for it.
devenv_derive_password() {
    [ -n "${DEVENV_SECRET_SALT:-}" ] \
        || die "DEVENV_SECRET_SALT is unset — set it in .env" 4
    printf '%s|%s|%s' "$DEVENV_SECRET_SALT" "$1" "$2" | sha256sum | cut -c1-32
}

# Owner attribution, in order of specificity. PAPERCLIP_AGENT_ID is injected
# by paperclip on every agent run, so leases are attributed automatically.
devenv_owner() {
    if [ -n "${DEVENV_OWNER:-}" ]; then
        echo "$DEVENV_OWNER"
    elif [ -n "${PAPERCLIP_AGENT_ID:-}" ]; then
        echo "agent:${PAPERCLIP_AGENT_ID}"
    else
        echo "$(id -un)@$(hostname)"
    fi
}

# Rewrite only the keys the caller is about to write; anything else in the file
# is preserved. Both arguments are files so KEY=VALUE lines never go through
# word splitting. This is the mechanism that lets a devenv lease and a podenv
# lease share one .env.
devenv_env_merge() {
    _env_file="$1"; _env_new="$2"
    _env_tmp="${_env_file}.envmerge.$$"
    : > "$_env_tmp"
    if [ -f "$_env_file" ]; then
        _env_drop="$(sed 's/=.*//' "$_env_new" | paste -sd'|' -)"
        grep -Ev "^(${_env_drop})=" "$_env_file" >> "$_env_tmp" || true
    fi
    cat "$_env_new" >> "$_env_tmp"
    mv "$_env_tmp" "$_env_file"
}
