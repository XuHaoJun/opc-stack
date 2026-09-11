#!/bin/sh
# Write /data/config/tdai-gateway.yaml if absent. Idempotent by design: every piece of
# state in this stack needs an unattended producer, because a clean `git clone` +
# scripts/setup.sh must end with everything working and no manual steps (AGENTS.md,
# 部署假設). A yaml placed by hand would simply not exist on the next machine.
#
# Only keys we actually mean to pin are written. The gateway starts fine with NO file
# at all, so this must never write a partial/invalid document — see the regression in
# tests/memory-scope.sh.
set -eu

CFG="${TDAI_GATEWAY_CONFIG:-/data/config/tdai-gateway.yaml}"
if [ -f "$CFG" ]; then
    echo "[tdai-config-seed] $CFG exists; leaving it alone"
    exit 0
fi
mkdir -p "$(dirname "$CFG")"
cat > "$CFG" <<'YAML'
# Managed by opc-tdai-config-seed.sh. Delete this file to have it regenerated.
#
# Promotion cadence. These are the parser defaults (MemoryCore/src/config.ts:582-590)
# written explicitly so the value is visible instead of implicit. Note the docstring in
# utils/pipeline-manager.ts:118,124 disagrees with the parser (it says 60/90); the
# parser wins.
memory:
  pipeline:
    everyNConversations: 5
    enableWarmup: true
    l1IdleTimeoutSeconds: 600
    l2DelayAfterL1Seconds: 10
    l2MinIntervalSeconds: 900
    l2MaxIntervalSeconds: 3600
    sessionActiveWindowHours: 24
  persona:
    triggerEveryN: 50
YAML
echo "[tdai-config-seed] wrote $CFG"
