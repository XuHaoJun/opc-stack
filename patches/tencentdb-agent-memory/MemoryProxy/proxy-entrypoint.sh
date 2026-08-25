#!/bin/sh
# TencentDB MemoryProxy entrypoint: reconcile /data/config.yaml from env vars
# on EVERY boot, then exec the proxy.
#
# Not "generate on first boot". config.yaml lives on a volume that survives
# image upgrades, so seed-once meant the proxy kept consuming the file the
# PREVIOUS version generated: keys a new release adds never appeared, and
# nothing anywhere reported the gap. This stack has already paid for that
# lesson twice — the front door's system_prompt and SOUL.md are both
# re-written from the image on every boot for exactly this reason.
#
# The file is a pure function of the environment, so reconciling costs nothing
# and there is no supported reason to hand-edit it. When the rendered content
# differs from what is on disk, the old file is kept as config.yaml.bak-<UTC>
# first — same courtesy hermes's own config migration extends — so a surprise
# is recoverable and visible.
set -eu

CONF="${PROXY_CONFIG_PATH:-/data/config.yaml}"

mkdir -p "$(dirname "$CONF")"
CONF_NEW="$CONF.opc-new"
cat > "$CONF_NEW" <<YAML
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

if [ ! -f "$CONF" ]; then
    mv "$CONF_NEW" "$CONF"
    echo "[proxy] generated $CONF"
elif cmp -s "$CONF_NEW" "$CONF"; then
    rm -f "$CONF_NEW"
    echo "[proxy] $CONF already matches the environment"
else
    _bak="$CONF.bak-$(date -u +%Y%m%dT%H%M%SZ)"
    cp "$CONF" "$_bak"
    mv "$CONF_NEW" "$CONF"
    echo "[proxy] reconciled $CONF from the environment (previous kept at $_bak)"
fi

exec node --import tsx/esm /app/src/index.ts --config "$CONF" "$@"
