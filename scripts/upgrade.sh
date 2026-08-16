#!/usr/bin/env bash
# Upgrade one component to a new upstream tag, then rebuild + redeploy.
#   scripts/upgrade.sh <buzz|hermes|paperclip|tencentdb> <tag>
#   e.g. scripts/upgrade.sh hermes v2026.9.1
#
# Flow: fetch tags → verify tag exists upstream → clean stale patches from the
# submodule worktree → checkout the tag → record new submodule pointer →
# re-apply patches → rebuild + redeploy that component's services.
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
  [hermes]="hermes"
  [paperclip]="paperclip"
  [tencentdb]="tencentdb-core tencentdb-bootstrap tencentdb-hub tencentdb-proxy"
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

echo "── checkout $PROJ: $OLD → $TAG ──"
# Drop stale patched files so a new version's checkout never collides with them.
find "$UP" -type d -name opc -prune -exec rm -rf {} +
git -C "$UP" checkout "$TAG"
git add "$UP"

echo "── re-apply patches ──"
scripts/prepare.sh

echo "── rebuild + redeploy ${SERVICES[$PROJ]} ──"
docker compose build ${SERVICES[$PROJ]}
docker compose up -d ${SERVICES[$PROJ]}

echo "── done: $PROJ → $TAG ──"
echo "verify: scripts/test-connectivity.sh"
