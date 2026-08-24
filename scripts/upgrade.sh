#!/usr/bin/env bash
# Upgrade one component to a new upstream tag, then rebuild + redeploy.
#   scripts/upgrade.sh <buzz|hermes|paperclip|tencentdb> <tag>
#   e.g. scripts/upgrade.sh hermes v2026.9.1
#
# Flow: fetch tags → verify tag exists upstream → clean stale patches from the
# submodule worktree → checkout the tag → record new submodule pointer →
# re-apply patches → rebuild + redeploy that component's runtime services.
#
# Hermes owns two images in this stack: the gateway/dashboard image and the
# Buzz frontdoor image, which bakes a Hermes ACP checkout. Upgrading Hermes
# aligns both pins and redeploys all three runtime services together.
#
# ⚠ patches/ were written against the pinned tag; a major upgrade may need
#   patch edits. Review `git -C upstream/<proj> log --oneline <old>..<tag>`
#   and adjust patches before rebuilding if in doubt.
set -euo pipefail
cd "$(dirname "$0")/.."

PROJ="${1:-}"
TAG="${2:-}"
if [ -z "$PROJ" ] || [ -z "$TAG" ]; then
  echo "usage: scripts/upgrade.sh <buzz|hermes|paperclip|tencentdb> <tag>"
  echo "  available tags: git -C upstream/<proj> ls-remote --tags origin"
  exit 1
fi

declare -A SERVICES=(
  [buzz]="buzz-keys buzz buzz-bootstrap frontdoor"
  [hermes]="frontdoor hermes hermes-dashboard"
  [paperclip]="paperclip"
  [tencentdb]="tencentdb-core tencentdb-bootstrap tencentdb-hub tencentdb-proxy"
)
# Dashboard uses the Hermes image but has no build section of its own.
# Hermes upgrades also rebuild frontdoor because its image bakes hermes-agent
# from the tag pinned in patches/buzz/Dockerfile.
declare -A BUILD_SERVICES=(
  [hermes]="frontdoor hermes"
)
if [ -z "${SERVICES[$PROJ]:-}" ]; then
  echo "unknown component '$PROJ' (pick from: ${!SERVICES[*]})"; exit 1
fi

# Component → submodule directory (tencentdb's submodule is NOT named after
# the component — same mismatch prepare.sh already handles).
declare -A SUBMODULE=(
  [buzz]=buzz
  [hermes]=hermes
  [paperclip]=paperclip
  [tencentdb]=tencentdb-agent-memory
)
UP="upstream/${SUBMODULE[$PROJ]}"

echo "── fetch + verify tag ──"
git -C "$UP" fetch origin --tags --prune
if ! git -C "$UP" ls-remote --tags origin "refs/tags/$TAG" "refs/tags/$TAG^{}" | grep -q .; then
  echo "tag '$TAG' not found on upstream origin (see list above)"; exit 1
fi
OLD="$(git -C "$UP" describe --tags --always)"
if [[ "$PROJ" == hermes ]]; then
  if [[ ! "$TAG" =~ ^v[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}$ ]]; then
    echo "Hermes target must be a date tag like v2026.8.19: $TAG" >&2
    exit 1
  fi
  pin_file="patches/buzz/Dockerfile"
  [ -f "$pin_file" ] || { echo "missing frontdoor Dockerfile: $pin_file" >&2; exit 1; }
  old_pin="$(sed -n -E 's/.*git clone --depth 1 --branch (v[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2})[[:space:]].*/\1/p' "$pin_file")"
  pin_count="$(printf '%s\n' "$old_pin" | sed '/^$/d' | wc -l)"
  [ "$pin_count" = 1 ] || {
    echo "expected exactly one frontdoor Hermes tag in $pin_file; found $pin_count" >&2
    exit 1
  }
fi

echo "── checkout $PROJ: $OLD → $TAG ──"
# Drop stale patched files so a new version's checkout never collides with them.
find "$UP" -type d -name opc -prune -exec rm -rf {} +
git -C "$UP" checkout "$TAG"
if [[ "$PROJ" == hermes && "$old_pin" != "$TAG" ]]; then
  sed -E -i "s|(git clone --depth 1 --branch )v[0-9.]+|\1${TAG}|" "$pin_file"
  echo "aligned frontdoor Hermes pin: $old_pin → $TAG"
fi
git add "$UP"
echo "── re-apply patches ──"
scripts/prepare.sh
BUILD_SERVICES_FOR_PROJ="${BUILD_SERVICES[$PROJ]:-${SERVICES[$PROJ]}}"
echo "── rebuild + redeploy ${SERVICES[$PROJ]} ──"
docker compose build $BUILD_SERVICES_FOR_PROJ
if [[ "$PROJ" == hermes ]]; then
  docker compose up -d --force-recreate ${SERVICES[$PROJ]}
else
  docker compose up -d ${SERVICES[$PROJ]}
fi

echo "── done: $PROJ → $TAG ──"
echo "verify: tests/connectivity.sh"
