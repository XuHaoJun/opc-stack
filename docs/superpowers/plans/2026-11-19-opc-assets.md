# OPC Assets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Manage local immutable asset revisions from the host and provision disposable materializations in trusted Paperclip Git worktrees.

**Architecture:** The operator writes a Docker volume through an isolated helper; Paperclip mounts it read-only. The tracked manifest pins a revision, and all worktree targets are published by a single no-clobber rename. Git and Paperclip own execution workspace lifecycle; the operator owns shared revision retirement.

**Tech Stack:** Bash, Python 3 standard library, Docker Compose, GNU coreutils, Git, Linux flock.

**Spec:** [Worktree Assets design](../specs/2026-11-18-worktree-assets-design.md).

## Global Constraints

- Keep Paperclip `v2026.1106.0`; do not reinstall or recreate the running stack.
- Production path `/opt/opc-assets/<store>/revisions/<digest-hex>/{inventory.json,payload/}`; manifest revision `sha256:<64 lowercase hex>`, version `1`.
- Worktree destinations `assets/` and `.worktree-assets-state/`; no assets or state for missing revisions, no hardlink copies, no network or bind mounts for the operator helper.
- No automatic GC; retirement requires the exact revision and manual confirmation. Cache expiration and Git restore points are incompatible with opted-in worktrees.

## Review Focus

- A complete tar stream followed by producer exit nonzero must not go live.
- An abandoned staging writer or concurrently created destination must not produce a partial materialization or overwrite an existing asset tree.
- A symlink or tracked path where a worktree control directory belongs must never be followed or modified.
- A parseable but corrupt published revision must not be mistaken for a missing revision.
- An empty store, the provision pause, and an ineligible worktree must not create worktree files; a successful reopen must not resurrect an old derivative.

## Task 1: Operator lifecycle

**Files:** `scripts/opc-assets`, `patches/paperclip/worktree-assets/asset-store.py`, `tests/opc-assets-store.py`.

**Interface:** Host `import <store> <host-dir> <entry>...`, `list [<store>]`, `retire <store> <revision>`; separate helper stage/publish with private token, canonical digest, and idempotent atomic publication.

- [x] Exercise missing command, invalid archive, producer failure, duplicate publish, and confirmed/cancelled retirement with scratch storage.
- [x] Implement safe file-only streaming transfer, normalized inventory, positive Compose volume/image resolution, no-clobber publication, and scoped retirement.
- [x] Run `python3 tests/opc-assets-store.py` and the isolated Docker operator smoke; expect all cases to pass.

## Task 2: Worktree lifecycle

**Files:** `patches/paperclip/worktree-assets/worktree-assets.py`, `tests/worktree-assets.py`.

**Interface:** `worktree-assets init|status` in linked worktree root; Python `run(command, *, cwd, store_root, env)` for local fixtures, production CLI uses the fixed read-only mount. Consume Task 1's on-disk format exactly.

- [x] Exercise missing/invalid revisions, hostile or tracked worktree paths, simultaneous init, namespace conflicts, and immutable pins using real scratch Git worktrees.
- [x] Implement opt-ins, mount/manifest/index/ignore checks, lock and private staging, reflink-aware clone, and non-clobber root publication with binding.
- [x] Run `python3 tests/worktree-assets.py`; expect all cases to pass. Prove reflink using distinct named volumes in the pinned image.

## Task 3: Package and verify integration

**Files:** `patches/paperclip/Dockerfile`, `docker-compose.yml`, `.env.example`, `patches/paperclip/patches/omp-acpx-runtime-env.patch`, `patches/paperclip/worktree-assets/provision-worktree.sh`, `tests/paperclip-worktree-assets.sh`, `tests/fixtures/paperclip-worktree-assets.mjs`, `SETUP.md`.

**Interface:** `/usr/local/bin/worktree-assets` and `/usr/local/lib/opc-assets/asset-store.py`, Compose named volume `opc-assets`, explicit `WORKTREE_ASSETS_ENABLED`, `WORKTREE_ASSETS_ALLOW_FULL_COPY`, and Paperclip retention switches.

- [x] Verify the missing CLI/mount baseline before installing the feature; never target the live project or use real private payloads.
- [x] Package scripts and the project provision wrapper, mount only on the Paperclip service, and ship operator and consumer instructions.
- [x] Validate resolved Compose, then exercise create, reuse after import, real terminal cleanup and reopen on the current pin without an LLM.
- [x] Review requirements, run focused checks, and commit only changes for this branch using the selective commit tool.

Verification: 12 worktree tests and 19 store tests passed. The isolated pinned-image gate exercised production heartbeat workspace preparation, reuse after host import, strict reflinks and explicit copy fallback, terminal cleanup/reopen, and TTY-confirmed retirement. No live deployment or private-source import was performed.
