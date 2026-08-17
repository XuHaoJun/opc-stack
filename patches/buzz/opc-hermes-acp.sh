#!/bin/sh
# buzz-acp spawns the agent subprocess as root (root is needed only for
# buzz-acp's own /keys access). Hermes must run as the hermes runtime uid
# (HERMES_UID/10000): the shared $HERMES_HOME (frontdoor-hermes volume) is
# also served by hermes-dashboard as uid 10000, and SQLite WAL state.db
# cannot be shared across two unix users — a root-owned state.db is
# read-only for uid 10000, which trips hermes's writability preflight and
# spams "TUI session store unavailable" while the dashboard loses its
# Sessions/Chat features. setpriv drops privileges while preserving the
# environment buzz-acp passes down (API keys, HERMES_HOME, ...); the stdio
# pipes stay valid across the uid change.
#
# Installed as /usr/local/libexec/hermes (not "opc-hermes-acp.sh") so
# buzz-acp's command-identity normalization keeps reporting harness=hermes
# and applies the hermes default env (HERMES_ACP_SKIP_CONFIGURED_MCP=1).
: "${HERMES_UID:=10000}"
: "${HERMES_GID:=10000}"
# The agent needs a writable HOME (/root is root-owned in this image), so
# point it at the shared home — matching the hermes image where the hermes
# user's home IS /opt/data. Set here, NOT in the entrypoint: entrypoint
# seeds (nix .nix-profile symlink, omp config) must stay at /root, because
# the dashboard's managed-files view resolves every entry under /opt/data
# and 403s anything escaping it ("Path outside managed files root").
export HOME="${HERMES_HOME:-/opt/data}"
# --clear-groups (not --init-groups): the buzz image has no passwd entry for
# uid 10000, and setpriv's initgroups lookup refuses unknown users.
exec setpriv --reuid="$HERMES_UID" --regid="$HERMES_GID" --clear-groups \
    /opt/hermes-venv/bin/hermes "$@"
