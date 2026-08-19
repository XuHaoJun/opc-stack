#!/bin/sh
# set-buzz-agent-owner.sh — bind the Buzz front-door agent to a named human.
#
# Resolves exactly one active human Buzz account (by display name or 64-hex
# pubkey) from the running buzz-db, validates the owner's pkey file on the
# host (regular file, owned by the current uid, no group/other permission
# bits), signs a public NIP-OA owner attestation through the isolated
# opc-nip-oa-sign helper (pkey on stdin only, --network none, disposable
# container), writes ONLY public configuration (BUZZ_ACP_AGENT_OWNER,
# BUZZ_AUTH_TAG, BUZZ_OWNER_KEY_FILE) to .env atomically, recreates
# frontdoor, and verifies the four ownership surfaces:
#   1. frontdoor log:  owner resolved from BUZZ_AUTH_TAG: <owner>
#   2. users.agent_owner_pubkey for the Hermes agent equals <owner>
#   3. latest Hermes kind 0 event carries the auth tag
#   4. latest Hermes kind 10100 event carries the auth tag
# Kind 24200 (ACP activity frames) is ephemeral and Desktop-local — the final
# user-visible check happens in Buzz Desktop, not here.
#
# Security invariants:
#   - the owner pkey never enters .env, compose configuration, argv, or logs;
#   - BUZZ_OWNER_KEY_FILE names a host-only file and is never passed to a
#     Compose service (docker-compose.yml passes only BUZZ_ACP_AGENT_OWNER and
#     BUZZ_AUTH_TAG to frontdoor; the test asserts BUZZ_OWNER_KEY_FILE is
#     absent from every service environment);
#   - a pre-existing BUZZ_ACP_AGENT_OWNER that differs from the resolved
#     account fails loudly before anything is written — no implicit rotation;
#   - the .env rewrite is atomic (temp file in the same directory, original
#     mode preserved, mv into place) and never duplicates the managed keys.
#
# Usage: scripts/set-buzz-agent-owner.sh <display-name-or-64-hex-pubkey>
# Env:   OPC_ENV_FILE (default: <repo>/.env) — test/operator override only.
set -eu

die() { echo "set-buzz-agent-owner: ERROR: $*" >&2; exit 1; }

[ "$#" -eq 1 ] || die "usage: $0 <display-name-or-64-hex-pubkey>"
selector="$1"
[ -n "$selector" ] || die "empty selector"

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
env_file="${OPC_ENV_FILE:-$repo_dir/.env}"
[ -f "$env_file" ] || die "env file not found: $env_file"
env_file="$(realpath "$env_file")"

is_hex64() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{64}$'; }

# ── 1. Resolve exactly one active human identity ─────────────────────────────
# The selector is passed through psql --set=selector=... and referenced with
# :'selector' (psql SQL-literal quoting); raw selector text never touches the
# SQL string.
IDENTITY_SQL="SELECT encode(pubkey, 'hex'), display_name,
       CASE WHEN agent_owner_pubkey IS NULL THEN 'human' ELSE 'agent' END
FROM users
WHERE deactivated_at IS NULL
  AND (
    lower(display_name) = lower(:'selector')
    OR encode(pubkey, 'hex') = lower(:'selector')
  )
ORDER BY encode(pubkey, 'hex');"

set +e
rows="$(docker compose exec -T buzz-db psql -U buzz -d buzz -A -t \
  --set=selector="$selector" -c "$IDENTITY_SQL" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || die "identity lookup failed (psql exit $rc): $(printf '%s' "$rows" | tail -n 1)"

n="$(printf '%s\n' "$rows" | sed '/^[[:space:]]*$/d' | wc -l)"
if [ "$n" -eq 0 ]; then
  die "no active Buzz account matches '$selector'"
fi
if [ "$n" -gt 1 ]; then
  die "ambiguous selector '$selector' matches $n accounts: $(printf '%s\n' "$rows" | tr '\n' ';')"
fi
row="$(printf '%s\n' "$rows" | sed '/^[[:space:]]*$/d' | head -n 1)"
owner_pubkey="$(printf '%s\n' "$row" | cut -f1)"
klass="$(printf '%s\n' "$row" | cut -f3)"
is_hex64 "$owner_pubkey" || die "resolved pubkey is not 64-hex: $owner_pubkey"
[ "$klass" = human ] || die "selected account '$selector' is $klass, not a human; refusing to bind an agent as owner"
echo "resolved: $selector -> $owner_pubkey"

# ── 2. Reject ownership rotation before any write ────────────────────────────
existing_owner="$(grep -E '^BUZZ_ACP_AGENT_OWNER=' "$env_file" | tail -n 1 | cut -d= -f2-)"
existing_owner="${existing_owner#\"}"; existing_owner="${existing_owner%\"}"
existing_owner="${existing_owner#\'}"; existing_owner="${existing_owner%\'}"
if [ -n "$existing_owner" ] && [ "$existing_owner" != "$owner_pubkey" ]; then
  die "Buzz agent is already owned by $existing_owner; refusing to rotate (run with that owner's account)"
fi

# ── 3. Resolve and validate the owner key file ───────────────────────────────
key_file="$(grep -E '^BUZZ_OWNER_KEY_FILE=' "$env_file" | tail -n 1 | cut -d= -f2-)"
key_file="${key_file#\"}"; key_file="${key_file%\"}"
key_file="${key_file#\'}"; key_file="${key_file%\'}"
if [ -z "$key_file" ]; then
  if [ -t 0 ]; then
    printf 'Owner key file path: ' >&2
    IFS= read -r key_file || die "no key path supplied"
  else
    die "BUZZ_OWNER_KEY_FILE is not set in $env_file — add BUZZ_OWNER_KEY_FILE=/path/to/pkey (regular file, mode 0600, owned by uid $(id -u)) and re-run"
  fi
fi
key_file="$(realpath "$key_file")" || die "cannot resolve key file: $key_file"
[ -f "$key_file" ] || die "key file is not a regular file: $key_file"
[ -r "$key_file" ] || die "key file is not readable: $key_file"
[ "$(stat -c %u "$key_file")" = "$(id -u)" ] || die "key file must be owned by uid $(id -u): $key_file"
mode="$(stat -c %a "$key_file")"
case "${mode#?}" in
  00) ;;
  *) die "key file must not grant group/other access (mode $mode): $key_file" ;;
esac

# ── 4. Read the agent pubkey (public; never read the agent nsec) ─────────────
set +e
agent_raw="$(docker compose run --rm --no-deps buzz-bootstrap cat /keys/agent.pub 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || die "cannot read agent pubkey (exit $rc): $(printf '%s' "$agent_raw" | tail -n 1)"
agent_pubkey="$(printf '%s' "$agent_raw" | sed '/^[[:space:]]*$/d' | tail -n 1 | tr -d '[:space:]')"
is_hex64 "$agent_pubkey" || die "invalid agent pubkey from /keys/agent.pub: $agent_pubkey"

# ── 5. Signer image from the compose config (IMAGE_PREFIX-controlled) ────────
set +e
compose_json="$(docker compose config --format json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || die "docker compose config failed (exit $rc): $(printf '%s' "$compose_json" | tail -n 1)"
image="$(printf '%s' "$compose_json" | jq -r '.services.frontdoor.image // empty')"
[ -n "$image" ] || die "frontdoor service image not found in compose config"
docker image inspect "$image" >/dev/null 2>&1 \
  || die "signer image not built: $image (run scripts/prepare.sh first)"

# ── 6. Sign the owner attestation (pkey only on stdin, --network none) ───────
set +e
tag="$(printf '%s\n' "$(cat "$key_file")" | docker run --rm -i --network none \
  --entrypoint /usr/local/bin/opc-nip-oa-sign "$image" "$agent_pubkey" "$owner_pubkey" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || die "owner attestation signing failed (exit $rc): $(printf '%s' "$tag" | tail -n 1)"
printf '%s' "$tag" | jq -e \
  --arg owner "$owner_pubkey" \
  '.[0] == "auth" and .[1] == $owner and .[2] == "" and (.[3] | test("^[0-9a-f]{128}$"))' >/dev/null \
  || die "signer returned an invalid auth tag: $(printf '%s' "$tag" | cut -c1-64)"

# ── 7. Atomic .env update (public values only; one canonical block) ──────────
env_dir="$(dirname "$env_file")"
env_mode="$(stat -c %a "$env_file")"
tmp_env="$(mktemp "$env_dir/.env.XXXXXX")"
trap 'rm -f "$tmp_env"' EXIT
awk -v owner="$owner_pubkey" -v tag="$tag" -v keyfile="$key_file" '
function emit_block() {
    print "BUZZ_ACP_AGENT_OWNER=" owner
    print "BUZZ_AUTH_TAG=" tag
    print "BUZZ_OWNER_KEY_FILE=" keyfile
}
/^(BUZZ_ACP_AGENT_OWNER|BUZZ_AUTH_TAG|BUZZ_OWNER_KEY_FILE)=/ {
    if (!emitted) { emit_block(); emitted = 1 }
    next
}
{ print }
END { if (!emitted) emit_block() }
' "$env_file" > "$tmp_env"
chmod "$env_mode" "$tmp_env"
mv "$tmp_env" "$env_file"
trap - EXIT

# ── 8. Recreate frontdoor so the new attestation takes effect ────────────────
docker compose up -d --no-deps --force-recreate frontdoor

# ── 9. Verify the four ownership surfaces (bounded, fails loudly) ────────────
wait_ok() { # wait_ok <boundary-label> <check-cmd...>
  label="$1"; shift
  i=0
  while [ "$i" -lt 10 ]; do
    if "$@" >/dev/null 2>&1; then
      echo "ok: $label"
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  die "verification failed: $label"
}

check_owner_log() {
  docker compose logs --no-color frontdoor 2>/dev/null \
    | grep -Fq "owner resolved from BUZZ_AUTH_TAG: $owner_pubkey"
}

MAPPING_SQL="SELECT encode(agent_owner_pubkey, 'hex')
FROM users
WHERE encode(pubkey, 'hex') = lower(:'agent')
  AND agent_owner_pubkey IS NOT NULL;"

KIND0_SQL="SELECT tags::text
FROM events
WHERE encode(pubkey, 'hex') = lower(:'agent') AND kind = 0
ORDER BY created_at DESC, id DESC
LIMIT 1;"

KIND10100_SQL="SELECT tags::text
FROM events
WHERE encode(pubkey, 'hex') = lower(:'agent') AND kind = 10100
ORDER BY created_at DESC, id DESC
LIMIT 1;"

check_mapping() {
  value="$(docker compose exec -T buzz-db psql -U buzz -d buzz -A -t \
    --set=agent="$agent_pubkey" -c "$MAPPING_SQL" 2>/dev/null \
    | sed '/^[[:space:]]*$/d' | tail -n 1 | tr -d '[:space:]')"
  [ -n "$value" ] && [ "$value" = "$owner_pubkey" ]
}

check_kind() { # check_kind <kind> <sql>
  kind="$1"; sql="$2"
  tags_text="$(docker compose exec -T buzz-db psql -U buzz -d buzz -A -t \
    --set=agent="$agent_pubkey" -c "$sql" 2>/dev/null \
    | sed '/^[[:space:]]*$/d' | tail -n 1)"
  [ -n "$tags_text" ] || return 1
  printf '%s' "$tags_text" | jq -e --argjson tag "$tag" 'any(. == $tag)' >/dev/null
}

wait_ok "frontdoor log: owner resolved from BUZZ_AUTH_TAG" check_owner_log
wait_ok "users.agent_owner_pubkey (Hermes)" check_mapping
wait_ok "latest Hermes kind 0 carries the auth tag" check_kind 0 "$KIND0_SQL"
wait_ok "latest Hermes kind 10100 carries the auth tag" check_kind 10100 "$KIND10100_SQL"

echo
echo "Buzz agent owner set: $selector -> $owner_pubkey"
echo "Public config written to $env_file; frontdoor recreated."
echo "note: kind 24200 ACP frames are ephemeral and Desktop-local — in Buzz"
echo "      Desktop, confirm 'managed by you' on a new Hermes turn."
