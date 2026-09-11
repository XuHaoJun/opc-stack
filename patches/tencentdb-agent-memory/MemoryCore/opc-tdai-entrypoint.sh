#!/bin/sh
# OPC entrypoint for tencentdb-core: seed /data/config/tdai-gateway.yaml, then
# run the CMD (the gateway). House pattern (cf. buzz-entrypoint.sh,
# hermes-entrypoint.sh): seeds run at boot, then exec "$@" so tini stays PID 1.
set -eu

/usr/local/bin/opc-tdai-config-seed.sh

exec "$@"
