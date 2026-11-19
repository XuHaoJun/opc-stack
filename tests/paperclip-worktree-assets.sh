#!/usr/bin/env bash
# Real pinned Paperclip services and embedded Postgres; no live stack data or LLM.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
project="opc-assets-test-$(basename "$tmp" | tr '[:upper:].' '[:lower:]-')"
image="$project/paperclip:local"
fixture="$project-worktree"
store="${project}_opc-assets"
work="$project-paperclip-data"
cleanup() {
    docker rm -f "$fixture" >/dev/null 2>&1 || true
    docker volume rm "$store" "$work" >/dev/null 2>&1 || true
    docker image rm "$image" >/dev/null 2>&1 || true
    rm -rf -- "$tmp"
}
trap cleanup EXIT

# Reuse the existing pinned application and precisely the feature's production
# COPY instructions; building the entire Paperclip tree is not needed here.
base=${OPC_ASSETS_TEST_BASE_IMAGE:-$(docker compose ps paperclip --status running --format '{{.Image}}')}
[[ -n "$base" ]] || { echo 'Set OPC_ASSETS_TEST_BASE_IMAGE to a local OPC Paperclip v2026.1106.0 image.' >&2; exit 2; }
mkdir -p "$tmp/context/opc"
cp -R patches/paperclip/worktree-assets "$tmp/context/opc/"
{
    printf 'FROM %s\n' "$base"
    grep '^COPY .*opc/worktree-assets/' patches/paperclip/Dockerfile
} | docker build --pull=false --network none --tag "$image" -f - "$tmp/context"

export COMPOSE_PROJECT_NAME="$project" IMAGE_PREFIX="$project"
docker compose config --format json | jq -e '
  [.services | to_entries[] | .key as $service | .value.volumes[]? |
    select(.source == "opc-assets") | [$service, .target, .read_only]]
  == [["paperclip", "/opt/opc-assets", true]]
' >/dev/null
docker volume create --label "com.docker.compose.project=$project" \
    --label com.docker.compose.volume=opc-assets "$store" >/dev/null
docker volume create "$work" >/dev/null
docker run --detach --rm --pull=never --network none --name "$fixture" --entrypoint /bin/sh \
    --mount "type=volume,src=$store,dst=/opt/opc-assets,readonly,volume-nocopy" \
    --mount "type=volume,src=$work,dst=/paperclip,volume-nocopy" \
    --env PAPERCLIP_GIT_CACHE_EXPIRATION_ENABLED=false \
    --env PAPERCLIP_GIT_RESTORE_POINTS_ENABLED=false \
    "$image" -ec 'chown node:node /paperclip; exec sleep infinity' >/dev/null

docker cp tests/fixtures/paperclip-worktree-assets.mjs "$fixture:/tmp/opc-assets.mjs"
docker exec --user node "$fixture" sh -ec '
    set -- /app/node_modules/.pnpm/tsx@*/node_modules/tsx/dist/loader.mjs
    exec node --import "$1" /tmp/opc-assets.mjs
' >"$tmp/fixture.log" 2>&1 &
runner=$!
for ((i=0; ; i++)); do
    if expected=$(docker exec "$fixture" cat /tmp/opc-assets-ready 2>/dev/null); then break; fi
    if ! kill -0 "$runner" 2>/dev/null || (( i >= 100 )); then
        cat "$tmp/fixture.log" >&2
        exit 1
    fi
    sleep .25
done
mkdir -p "$tmp/source/Data" "$tmp/source/game"
printf 'reference\n' > "$tmp/source/Data/reference"
printf 'template\n' > "$tmp/source/game/template"
actual=$(./scripts/opc-assets import fixture "$tmp/source" Data game)
[[ "$actual" == "$expected" ]] || { printf 'Unexpected revision: %s (expected %s)\n' "$actual" "$expected" >&2; exit 1; }
./scripts/opc-assets list fixture | grep -F -- "$actual"
docker exec --user node "$fixture" touch /tmp/opc-assets-imported
if wait "$runner"; then cat "$tmp/fixture.log"; else cat "$tmp/fixture.log" >&2; exit 1; fi

# Interactive retirement must not treat a non-interactive pipe (or a typo)
# as authority. A real PTY exercises the operator input path.
if ./scripts/opc-assets retire fixture "$actual" </dev/null >"$tmp/retire.log" 2>&1; then
    echo 'Retirement unexpectedly accepted non-interactive input.' >&2
    exit 1
fi
./scripts/opc-assets list fixture | grep -F -- "$actual" >/dev/null
docker stop "$fixture" >/dev/null
printf '%s\n' "$actual" | script -qec "./scripts/opc-assets retire fixture $actual" /dev/null
listed=$(./scripts/opc-assets list)
[[ "$listed" != *"$actual"* ]]
printf 'PASS host import/list and interactive retirement of the exact revision\n'
