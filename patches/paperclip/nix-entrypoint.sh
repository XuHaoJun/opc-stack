#!/bin/sh
# Paperclip entrypoint: seed the /nix volume, then hand off to the upstream
# docker-entrypoint.sh (uid remap + gosu node) with the original CMD.
set -eu

. /usr/local/bin/opc-nix-seed.sh
opc_nix_seed

exec "$@"
