#!/bin/sh
# TencentDB MemoryProxy entrypoint: generate /data/config.yaml from env vars
# on first boot, then exec the proxy.
set -eu

CONF="${PROXY_CONFIG_PATH:-/data/config.yaml}"

if [ ! -f "$CONF" ]; then
    mkdir -p "$(dirname "$CONF")"
    cat > "$CONF" <<YAML
server:
  host: 0.0.0.0
  port: 8096
upstream:
  url: "${PROXY_UPSTREAM_URL:-https://api.openai.com/v1}"
  apiKey: "${PROXY_UPSTREAM_API_KEY:-}"
redis:
  enabled: false
storage:
  enabled: true
  backend: sqlite
  sqlite:
    dbPath: "${PROXY_DB_PATH:-/data/tdai-memory-proxy/proxy.db}"
injection:
  enabled: true
  injectors: [skill, knowledge, tdai-memory]
extraction:
  enabled: true
  extractors: [skill, tdai-memory]
sessionInit:
  enabled: true
tdai:
  enabled: true
  endpoint: "${PROXY_TDAI_ENDPOINT:-http://tencentdb-core:8420}"
  apiKey: "${PROXY_TDAI_API_KEY:-}"
  serviceId: default
  memory:
    enabled: true
    inject: true
    writeL0: true
    recallL1: true
    injectL2L3: true
coreSkill:
  endpoint: "${PROXY_TDAI_ENDPOINT:-http://tencentdb-core:8420}"
  serviceToken: "${PROXY_TDAI_API_KEY:-}"
  serviceId: context-proxy
knowledge:
  enabled: true
  endpoint: "${PROXY_KNOWLEDGE_ENDPOINT:-http://tencentdb-hub:8424}"
  serviceToken: "${PROXY_KNOWLEDGE_TOKEN:-}"
  serviceId: context-proxy
auth:
  enabled: false
YAML
    echo "[proxy] generated $CONF"
fi

exec node --import tsx/esm /app/src/index.ts --config "$CONF" "$@"
