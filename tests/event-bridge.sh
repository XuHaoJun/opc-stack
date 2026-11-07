#!/usr/bin/env bash
# Offline gate for the event bridge: the unit suite runs *inside* the built
# image, so it exercises the same python3/sqlite3 the service uses. No live
# stack, no network, no Paperclip/Buzz required.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="$(docker compose config --format json | jq -r '.services["event-bridge"].image')"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "FAIL  $IMAGE missing — run: docker compose build event-bridge" >&2
    exit 1
fi

docker compose run --rm --no-deps -T --entrypoint python3 event-bridge \
    -m unittest discover -s /opt/opc-bridge/tests -t /opt/opc-bridge -v
