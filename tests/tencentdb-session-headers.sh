#!/usr/bin/env bash
# Wire-level regression for TencentDB's direct OpenCode Go calls.
# Builds the source stages that contain the real AI SDK clients, then runs a
# local fake OpenAI-compatible server inside each builder. The fake endpoint is
# named opencode.ai so endpoint gating is exercised without contacting the WAN.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-all}"
case "$MODE" in
  all|core|knowledge|proxy) ;;
  *) echo "usage: tests/tencentdb-session-headers.sh [all|core|knowledge|proxy]" >&2; exit 2 ;;
esac

command -v docker >/dev/null || { echo "FAIL docker is required" >&2; exit 1; }

scripts/prepare.sh

FIXTURE="$PWD/tests/fixtures/tencentdb-session-header.mjs"
CORE_IMAGE="opc/tencentdb-session-test-core:$$"
KNOWLEDGE_IMAGE="opc/tencentdb-session-test-knowledge:$$"
PROXY_IMAGE="opc/tencentdb-session-test-proxy:$$"
cleanup() {
  docker image rm -f "$CORE_IMAGE" "$KNOWLEDGE_IMAGE" "$PROXY_IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_core() {
  echo "── build MemoryCore test stage ──"
  docker build --target deps-builder --tag "$CORE_IMAGE" \
    --file upstream/tencentdb-agent-memory/MemoryCore/opc/Dockerfile \
    upstream/tencentdb-agent-memory/MemoryCore
  echo "── run MemoryCore wire regression ──"
  docker run --rm --network=none --add-host=opencode.ai:127.0.0.1 \
    --volume "$FIXTURE:/tmp/tencentdb-session-header.mjs:ro" \
    "$CORE_IMAGE" node --import tsx /tmp/tencentdb-session-header.mjs core /build
}

run_knowledge() {
  echo "── build MemoryKnowledge test stage ──"
  docker build --target knowledge-builder --tag "$KNOWLEDGE_IMAGE" \
    --file upstream/tencentdb-agent-memory/opc/hub.Dockerfile \
    upstream/tencentdb-agent-memory
  echo "── run MemoryKnowledge wire regression ──"
  docker run --rm --network=none --add-host=opencode.ai:127.0.0.1 \
    --volume "$FIXTURE:/tmp/tencentdb-session-header.mjs:ro" \
    "$KNOWLEDGE_IMAGE" node --import tsx /tmp/tencentdb-session-header.mjs knowledge /build/knowledge
}

run_proxy() {
  echo "── build MemoryProxy test stage ──"
  docker build --target deps-builder --tag "$PROXY_IMAGE" \
    --file upstream/tencentdb-agent-memory/MemoryProxy/opc/proxy.Dockerfile \
    upstream/tencentdb-agent-memory/MemoryProxy
  echo "── run MemoryProxy wire regression ──"
  docker run --rm --network=none --add-host=opencode.ai:127.0.0.1 \
    --volume "$FIXTURE:/tmp/tencentdb-session-header.mjs:ro" \
    "$PROXY_IMAGE" node --import tsx /tmp/tencentdb-session-header.mjs proxy /app
}

case "$MODE" in
  all) run_core; run_knowledge; run_proxy ;;
  core) run_core ;;
  knowledge) run_knowledge ;;
  proxy) run_proxy ;;
esac

echo "result: TencentDB OpenCode session header regression passed"
