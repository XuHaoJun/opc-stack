#!/usr/bin/env bash
# Exercise the real backup/restore helpers on isolated disposable Docker volumes.
# No live stack containers or volumes are touched.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
fixture="$(mktemp -d)"
project="opc-restore-smoke-$$"
volumes="paperclip-data opc-prototypes opc-prototyper-home opc-keys"
cleanup() {
  for volume in $volumes; do docker volume rm "$project"_"$volume" >/dev/null 2>&1 || true; done
  rm -rf "$fixture"
}
trap cleanup EXIT
mkdir -p "$fixture/.claude/skills/upgrade-opc-stack/scripts" "$fixture/scripts"
cp .claude/skills/upgrade-opc-stack/scripts/{backup,restore}-volumes.sh \
  "$fixture/.claude/skills/upgrade-opc-stack/scripts/"
cp scripts/load-env.sh "$fixture/scripts/"
printf 'COMPOSE_PROJECT_NAME=%s\n' "$project" > "$fixture/.env"
printf 'services:\n' > "$fixture/docker-compose.yml"
for service in paperclip paperclip-bootstrap podenv host-sync-claude buzz-keys tencentdb-bootstrap devenv-expert-leases; do
  printf '  %s:\n    image: alpine:3\n' "$service" >> "$fixture/docker-compose.yml"
done
for volume in $volumes; do
  docker volume create "$project"_"$volume" >/dev/null
  docker run --rm -v "$project"_"$volume":/data alpine:3 \
    sh -c 'printf before > /data/retained'
done
bash "$fixture/.claude/skills/upgrade-opc-stack/scripts/backup-volumes.sh" \
  paperclip backup old new
for volume in $volumes; do
  docker run --rm -v "$project"_"$volume":/data alpine:3 \
    sh -c 'printf after > /data/retained; mkdir /data/new-version-only; printf stale > /data/new-version-only/state'
done
bash "$fixture/.claude/skills/upgrade-opc-stack/scripts/restore-volumes.sh" paperclip backup
for volume in $volumes; do
  docker run --rm -v "$project"_"$volume":/data alpine:3 \
    sh -c '[ "$(cat /data/retained)" = before ] && [ ! -e /data/new-version-only ]' \
    || { echo "FAIL restored $volume retains post-snapshot state" >&2; exit 1; }
done
echo 'PASS snapshot restores original contents and removes post-snapshot files in all four durable volumes'
