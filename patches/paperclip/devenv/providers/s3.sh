#!/bin/sh
# devenv s3 provider — RustFS object storage.
#
# Contract (see the spec's "Resource provider 契約"):
#   s3_provision <key> <slug>   idempotent create, prints KEY=VALUE lines
#   s3_release   <key> <slug>   idempotent remove
#   s3_probe                    backend reachability
#
# Isolation: one bucket, one IAM user, one bucket-scoped policy per lease
# named devenv-<key>. Tenant secrets are derived, not stored.

DEVENV_S3_HOST="${DEVENV_S3_HOST:-devenv-s3}"
DEVENV_S3_PORT="${DEVENV_S3_PORT:-9000}"
DEVENV_S3_ROOT_USER="${DEVENV_S3_ROOT_USER:-devenv-admin}"
DEVENV_S3_ROOT_PASSWORD="${DEVENV_S3_ROOT_PASSWORD:-devenv-object-storage}"

s3_mc_init() {
    _s3mi_user="$(jq -nr --arg v "$DEVENV_S3_ROOT_USER" '$v|@uri')" || return 1
    _s3mi_password="$(jq -nr --arg v "$DEVENV_S3_ROOT_PASSWORD" '$v|@uri')" || return 1
    MC_HOST_devenv="http://${_s3mi_user}:${_s3mi_password}@${DEVENV_S3_HOST}:${DEVENV_S3_PORT}"
    export MC_HOST_devenv
}

s3_probe() {
    s3_mc_init >/dev/null 2>&1 && mc ready devenv >/dev/null 2>&1
}

s3_name() { printf 'devenv-%s\n' "$1"; }

s3_provision() {
    _s3p_key="$1"; _s3p_slug="$2"
    s3_mc_init || die "S3 reconciliation failed for '$_s3p_key'" 4

    _s3p_bucket="$(s3_name "$_s3p_key")"
    _s3p_pw="$(devenv_derive_password "$_s3p_key" s3)"

    mc mb --ignore-existing "devenv/$_s3p_bucket" >/dev/null 2>&1 \
        || die "S3 reconciliation failed for '$_s3p_key'" 4

    mc admin user add devenv "$_s3p_bucket" "$_s3p_pw" >/dev/null 2>&1 \
        || die "S3 reconciliation failed for '$_s3p_key'" 4

    _s3p_policy_file="$(mktemp)"
    chmod 600 "$_s3p_policy_file"
    cat >"$_s3p_policy_file" <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"],
      "Resource": ["arn:aws:s3:::$_s3p_bucket"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::$_s3p_bucket/*"]
    }
  ]
}
POLICY

    mc admin policy create devenv "$_s3p_bucket" "$_s3p_policy_file" >/dev/null 2>&1 \
        || { rm -f "$_s3p_policy_file"; die "S3 reconciliation failed for '$_s3p_key'" 4; }

    mc admin policy attach devenv "$_s3p_bucket" --user "$_s3p_bucket" >/dev/null 2>&1 \
        || { rm -f "$_s3p_policy_file"; die "S3 reconciliation failed for '$_s3p_key'" 4; }

    rm -f "$_s3p_policy_file"

    printf 'AWS_ENDPOINT_URL=http://%s:%s\n' "$DEVENV_S3_HOST" "$DEVENV_S3_PORT"
    printf 'AWS_ACCESS_KEY_ID=%s\n' "$_s3p_bucket"
    printf 'AWS_SECRET_ACCESS_KEY=%s\n' "$_s3p_pw"
    printf 'AWS_REGION=us-east-1\n'
    printf 'S3_BUCKET=%s\n' "$_s3p_bucket"
    printf 'S3_FORCE_PATH_STYLE=true\n'
}

s3_release() {
    _s3r_key="$1"; _s3r_slug="$2"
    _s3r_name="$(s3_name "$_s3r_key")"

    s3_mc_init >/dev/null 2>&1 || die "cannot list S3 users" 4

    _users="$(mc admin user list devenv --json 2>/dev/null)" || die "cannot list S3 users" 4
    _policies="$(mc admin policy list devenv --json 2>/dev/null)" || die "cannot list S3 policies" 4
    _buckets="$(mc ls devenv --json 2>/dev/null)" || die "cannot list S3 buckets" 4

    # Bucket must be removed first (force empties it).
    if printf '%s\n' "$_buckets" | jq -e --arg name "$_s3r_name" 'select(.key == ($name + "/"))' >/dev/null 2>&1; then
        mc rb --force "devenv/$_s3r_name" >/dev/null 2>&1 || die "cannot list S3 buckets" 4
    fi

    if printf '%s\n' "$_users" | jq -e --arg name "$_s3r_name" 'select(.accessKey == $name)' >/dev/null 2>&1; then
        mc admin user remove devenv "$_s3r_name" >/dev/null 2>&1 || die "cannot list S3 users" 4
    fi

    if printf '%s\n' "$_policies" | jq -e --arg name "$_s3r_name" 'select(.policy == $name)' >/dev/null 2>&1; then
        mc admin policy remove devenv "$_s3r_name" >/dev/null 2>&1 || die "cannot list S3 policies" 4
    fi
}
