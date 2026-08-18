#!/bin/sh
# opc-prototype-restore.sh — bring preview servers back after a restart.
#
# Backgrounded by the entrypoint. Runtime services are child processes of the
# paperclip server, so every container recreate or restart kills them, and
# Paperclip has no reconciler that acts on the desiredState it records. Without
# this, a prototype's URL silently dies on any `docker compose up -d` and stays
# dead until someone notices and starts it by hand.
#
# Runs in the background because the API it needs is served by the process this
# entrypoint is about to exec — blocking here would deadlock the boot.
#
# Never fatal: this is recovery, not a prerequisite. Everything it might fix is
# also fixable by hand with `prototype expose <name> --start`.
opc_prototype_restore_bg() {
    [ -d "${PROTOTYPE_ROOT:-/prototypes}" ] || return 0
    (
        _pr_url="http://127.0.0.1:${PORT:-3100}/api/health"
        # ~5 min: a cold start migrates the embedded database and can be slow,
        # and giving up early would leave exactly the silent-dead-URL state
        # this exists to prevent.
        _pr_n=0
        while [ "$_pr_n" -lt 100 ]; do
            if curl -fsS -o /dev/null --max-time 3 "$_pr_url" 2>/dev/null; then break; fi
            _pr_n=$((_pr_n + 1)); sleep 3
        done
        if [ "$_pr_n" -ge 100 ]; then
            echo "[prototype-restore] paperclip did not become healthy — skipping" >&2
            return 0
        fi
        # The board key is mirrored by paperclip-bootstrap, which on a first
        # boot has not run yet. Nothing to restore then anyway.
        if [ ! -s "${BOARD_KEY_FILE:-/paperclip/.opc/board-api.key}" ]; then
            echo "[prototype-restore] no board key yet — skipping (first boot)" >&2
            return 0
        fi
        prototype restore 2>&1 | sed 's/^prototype:/[prototype-restore]/' || true
    ) &
}
