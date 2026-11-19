#!/bin/sh
if ! command -v worktree-assets >/dev/null 2>&1; then
    if [ -e .worktree-assets.json ] || [ -L .worktree-assets.json ] ||
       [ -e .worktree-assets-state ] || [ -L .worktree-assets-state ]; then
        echo 'worktree-assets CLI missing from the Paperclip image' >&2
        exit 3
    fi
    exit 0
fi

rc=0
worktree-assets init || rc=$?
[ "$rc" -eq 1 ] && exit 0  # init reported a missing revision
exit "$rc"
