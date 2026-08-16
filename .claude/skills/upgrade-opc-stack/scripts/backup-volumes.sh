#!/usr/bin/env bash
# Backup the stateful volumes of one OPC component.
#   backup-volumes.sh <buzz|hermes|paperclip|tencentdb> <backup-dir> [old-tag] [new-tag]
#
# Stops the component's services (volume-owning containers MUST be stopped
# for a consistent tar), tars each stateful volume into <backup-dir>, then
# writes meta.txt + manifest.sha256. Refuses to overwrite an existing backup
# dir. Leaves the component STOPPED — continue with the upgrade, or resume
# with `docker compose up -d <services>`.
#
# Stateful per component (mirror of references/risk-checklist.md):
#   buzz      → buzz-pgdata buzz-redisdata buzz-miniodata buzz-git frontdoor-hermes opc-keys
#   hermes    → hermes-data
#   paperclip → paperclip-data
#   tencentdb → tencentdb-core-data tencentdb-hub-data tencentdb-proxy-data
# Regenerable caches (*-nix, *-omp) are never backed up.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO"

PROJ="${1:-}"
BKDIR="${2:-}"
OLD="${3:-unknown}"
NEW="${4:-unknown}"
usage() { echo "usage: backup-volumes.sh <buzz|hermes|paperclip|tencentdb> <backup-dir> [old-tag] [new-tag]"; exit 1; }
[ -n "$PROJ" ] && [ -n "$BKDIR" ] || usage
[ -f .env ] || { echo "FAIL  no .env — run scripts/setup.sh first"; exit 1; }
set -a; . ./.env; set +a
PNAME="${COMPOSE_PROJECT_NAME:-opc}"

declare -A STOP_SERVICES=(
  [buzz]="buzz-db buzz-redis buzz-minio buzz-minio-init buzz-keys buzz buzz-bootstrap frontdoor"
  [hermes]="hermes"
  [paperclip]="paperclip"
  [tencentdb]="tencentdb-core tencentdb-bootstrap tencentdb-hub tencentdb-proxy"
)
declare -A VOLUMES=(
  [buzz]="buzz-pgdata buzz-redisdata buzz-miniodata buzz-git frontdoor-hermes opc-keys"
  [hermes]="hermes-data"
  [paperclip]="paperclip-data"
  [tencentdb]="tencentdb-core-data tencentdb-hub-data tencentdb-proxy-data"
)
[ -n "${VOLUMES[$PROJ]:-}" ] || usage

MANIFEST="$BKDIR/manifest.sha256"
[ ! -e "$MANIFEST" ] || { echo "FAIL  $BKDIR already contains a backup (manifest exists)"; exit 1; }
mkdir -p "$BKDIR"

echo "── stop ${PROJ} services (consistent volume tars) ──"
docker compose stop ${STOP_SERVICES[$PROJ]}

echo "── tar stateful volumes → $BKDIR ──"
for v in ${VOLUMES[$PROJ]}; do
  full="${PNAME}_${v}"
  docker volume inspect "$full" >/dev/null 2>&1 || { echo "FAIL  volume $full missing (compose never created it?)"; exit 1; }
  echo "  $v"
  docker run --rm -v "$full":/data -v "$BKDIR":/backup alpine:3 tar czf "/backup/${v}.tar.gz" -C /data .
done

echo "── write meta + manifest ──"
{
  echo "proj=$PROJ"
  echo "old=$OLD"
  echo "new=$NEW"
  echo "created=$(date -Iseconds)"
  echo "volumes=${VOLUMES[$PROJ]}"
} > "$BKDIR/meta.txt"
(cd "$BKDIR" && sha256sum ./*.tar.gz) > "$MANIFEST"

echo "backup: done → $BKDIR ($(wc -l < "$MANIFEST") volumes, component left stopped)"
echo "resume without upgrading: docker compose up -d ${STOP_SERVICES[$PROJ]}"
