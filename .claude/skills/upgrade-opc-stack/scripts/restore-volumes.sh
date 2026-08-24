#!/usr/bin/env bash
# Restore a volume backup made by backup-volumes.sh (rollback step).
#   restore-volumes.sh <buzz|hermes|paperclip|tencentdb> <backup-dir>
#
# Verifies meta.txt matches the requested component and manifest.sha256
# checksums pass, stops the component's services, untars each volume in
# place, then prints the rebuild/resume commands. Containers MUST be stopped
# while their data volumes are replaced.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$REPO"

PROJ="${1:-}"
BKDIR="${2:-}"
usage() { echo "usage: restore-volumes.sh <buzz|hermes|paperclip|tencentdb> <backup-dir>"; exit 1; }
[ -n "$PROJ" ] && [ -n "$BKDIR" ] || usage
[ -f .env ] || { echo "FAIL  no .env — run scripts/setup.sh first"; exit 1; }
. scripts/load-env.sh
opc_load_env .env
PNAME="${COMPOSE_PROJECT_NAME:-opc}"
[ -d "$BKDIR" ] || { echo "FAIL backup directory does not exist: $BKDIR"; exit 1; }
# Canonicalize before checksum and Docker bind-mount operations; callers use
# relative paths such as backups/hermes-... .
BKDIR="$(cd "$BKDIR" && pwd)"

declare -A STOP_SERVICES=(
  [buzz]="buzz-db buzz-redis buzz-minio buzz-minio-init buzz-keys buzz buzz-bootstrap frontdoor"
  # Hermes restores replace the shared profile/frontdoor homes as well as the
  # gateway data volume, so every writer must be stopped first.
  [hermes]="hermes hermes-dashboard frontdoor"
  [paperclip]="paperclip"
  [tencentdb]="tencentdb-core tencentdb-bootstrap tencentdb-hub tencentdb-proxy"
)

MANIFEST="$BKDIR/manifest.sha256"
META="$BKDIR/meta.txt"
[ -f "$MANIFEST" ] || { echo "FAIL  no manifest.sha256 in $BKDIR — not a backup dir"; exit 1; }
[ -f "$META" ] || { echo "FAIL  no meta.txt in $BKDIR — not a backup dir"; exit 1; }

# component must match the backup
[ "$(grep -E '^proj=' "$META" | cut -d= -f2)" = "$PROJ" ] || { echo "FAIL  backup meta is for a different component"; exit 1; }

# integrity gate: every tar must checksum before we touch any volume
(cd "$BKDIR" && sha256sum -c "$MANIFEST") || { echo "FAIL  backup corrupt (checksum mismatch) — refusing to restore"; exit 1; }

VOLS="$(grep -E '^volumes=' "$META" | cut -d= -f2-)"
[ -n "$VOLS" ] || { echo "FAIL  meta.txt has no volumes= line"; exit 1; }
if [ "$PROJ" = hermes ] && [ "$VOLS" != "hermes-data hermes-profiles frontdoor-hermes" ]; then
  echo "FAIL Hermes backup must contain hermes-data hermes-profiles frontdoor-hermes; refusing partial rollback" >&2
  exit 1
fi

echo "── stop ${PROJ} services ──"
docker compose stop ${STOP_SERVICES[$PROJ]}

echo "── untar volumes from $BKDIR ──"
for v in $VOLS; do
  full="${PNAME}_${v}"
  docker volume inspect "$full" >/dev/null 2>&1 || { echo "  (creating missing volume $full)"; docker volume create "$full" >/dev/null; }
  echo "  restore $v"
  docker run --rm -v "$full":/data -v "$BKDIR":/backup alpine:3 tar xzf "/backup/${v}.tar.gz" -C /data
done

echo "restore: done — volumes replaced with backup contents"
echo "next: rebuild + start the old tag, e.g.:"
echo "  git -C upstream/${PROJ} checkout <old-tag>  (or: scripts/upgrade.sh ${PROJ} <old-tag>)"
echo "  scripts/prepare.sh && docker compose up -d --build ${STOP_SERVICES[$PROJ]}"
