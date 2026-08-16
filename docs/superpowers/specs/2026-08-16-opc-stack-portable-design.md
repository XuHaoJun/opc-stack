# OPC Stack — Portable Repo Design

Date: 2026-08-16 · Status: approved (user picked overlay-rsync + name `opc-stack`)

## Problem

The stack (buzz / hermes / paperclip / tencentdb-agent-memory) was developed
in a flat working directory: four upstream clones under `learn-projects/`
with hand-copied `opc/` customizations, hardcoded `opc/` image prefixes, and
no version control or upgrade path. Goal: a version-controlled, portable
repo where a new machine only needs `.env` filled in, and upgrading a
component is a tag change + rebuild.

## Facts verified before design

- All customizations are new files under each repo's `opc/` dir — zero
  upstream file modifications → overlay approach is clean.
- All four pinned tags exist on upstream (`git ls-remote` verified):
  buzz `desktop-v0.5.14`, hermes `v2026.8.13`, paperclip
  `canary/v2026.722.1-canary.0`, tencentdb `v2.0.0` → submodule pointers
  clone successfully on a new machine.
- `omp` is not referenced by compose (nix installs it from GitHub) → not a
  submodule.

## Decisions

1. **`upstream/` = git submodules** pinned to tag commits; never edited in place.
2. **`patches/` = single source of local customization.** `scripts/prepare.sh`
   rsyncs `patches/<proj>/` → `upstream/<proj>/opc/` (idempotent, run before
   every build). Rejected alternatives: fork-and-commit (4 forks to maintain,
   rebase on every upgrade), BuildKit additional contexts (rewrites all
   Dockerfiles, depends on recent compose — anti-portable).
3. **Image prefix + project name via env**: `image: ${IMAGE_PREFIX:-opc}/...`
   (9 references), `name: ${COMPOSE_PROJECT_NAME:-opc}`. Volumes use short
   names → follow project name automatically; two stacks can coexist.
4. **`scripts/upgrade.sh <proj> <tag>`**: fetch → verify tag on upstream →
   drop stale `opc/` from submodule worktree (checkout-collision safety) →
   checkout → record gitlink → re-apply patches → rebuild + redeploy the
   component's services.
5. **`scripts/setup.sh`** (new machine): .env bootstrap (copy + hints for
   OPENCODE_API_KEY / BUZZ_RELAY_URL LAN IP) → submodule init → prepare →
   `up -d --build`. Idempotent.
6. **`scripts/test-connectivity.sh`**: container states (docker inspect),
   host→published-port HTTP probes (buzz `/_readiness`; hermes dashboard
   + API; paperclip `/api/health`; tencentdb core `/health`, panel, knowledge,
   proxy), and internal link frontdoor→relay via `buzz channels list`.
   Zero LLM calls.
7. **`BUZZ_RELAY_URL` default → `ws://localhost:3000`** in .env.example
   (was a hardcoded LAN IP); setup.sh prints the detected LAN IP as a hint.

## Files

- Modified: `docker-compose.yml` (name, 9× image prefix, 8× build context),
  `.env.example` (IMAGE_PREFIX, COMPOSE_PROJECT_NAME, relay URL),
  `AGENTS.md`, `SETUP.md`
- Created: `scripts/{prepare,setup,upgrade,test-connectivity}.sh`,
  `patches/{buzz,hermes,paperclip,tencentdb-agent-memory}/…` (16 files
  copied verbatim from the old `opc/` trees), `.gitignore`

## Verification

Fresh clone to /tmp → `git submodule update --init` → copy real `.env` →
`scripts/setup.sh` (full build) → `scripts/test-connectivity.sh` all PASS.
