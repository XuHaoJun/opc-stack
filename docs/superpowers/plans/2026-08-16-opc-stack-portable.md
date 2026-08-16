# OPC Stack Portable Repo — Implementation Plan

> **For agentic workers:** steps use checkbox (`- [ ]`) syntax.

**Goal:** version-controlled, portable opc-stack repo (submodules + patches
overlay + scripts) proven by a fresh-clone bring-up.

**Architecture:** `upstream/` = 4 git submodules pinned to upstream tags;
`patches/` = only customization source, rsynced onto `upstream/<proj>/opc/`
by `scripts/prepare.sh` before builds; compose parametrizes image prefix and
project name via env; setup/upgrade/test scripts encapsulate the workflows.

**Tech Stack:** bash, docker compose, git submodules, rsync.

## Global Constraints

- Never modify files inside `upstream/` directly — only `patches/`.
- All four submodule tags must stay on the commits verified at design time
  (buzz desktop-v0.5.14, hermes v2026.8.13, paperclip canary/v2026.722.1-canary.0,
  tencentdb v2.0.0) unless explicitly upgraded.
- Image references use `${IMAGE_PREFIX:-opc}`; project name `${COMPOSE_PROJECT_NAME:-opc}`.
- Test script must never call an LLM.
- `.env` is gitignored; `.env.example` is the portable template.

---

### Task 1: Restructure directory into repo + submodules

**Files:**
- Rename `/home/noah/nodails-2` → `/home/noah/opc-stack`
- Create: `.gitignore`
- Modify: `.gitmodules` (via `git submodule add`)

- [ ] `mv nodails-2 opc-stack && git init` (name/email: Noah <noah@localhost>)
- [ ] `mv learn-projects upstream`
- [ ] Copy `upstream/<p>/opc/` trees into `patches/<p>/` (buzz, hermes,
      paperclip; tencentdb also `MemoryProxy/opc`) — then `diff -r` to prove
      byte-identical, then `rm -rf` the four repos and `upstream/omp`
- [ ] `git submodule add <url> upstream/<p>` × 4; `git -C upstream/<p>
      checkout <tag>` in each; verify `git describe --tags` matches design
- [ ] `.gitignore`: `.env`, `.env.bak`, `*.log`, `node_modules/`, editor files

### Task 2: scripts/

**Files:** Create `scripts/prepare.sh`, `scripts/setup.sh`,
`scripts/upgrade.sh`, `scripts/test-connectivity.sh` (chmod +x)

- [ ] `prepare.sh`: for each of buzz/hermes/paperclip/tencentdb-agent-memory
      (+ MemoryProxy), `mkdir -p upstream/<p>/opc && rsync -a --delete
      patches/<p>/ upstream/<p>/opc/`; guard: missing `upstream/<p>` → error
      "run git submodule update --init"
- [ ] `setup.sh`: .env copy-if-missing + LAN-IP hint → `git submodule update
      --init --recursive` → `prepare.sh` → `docker compose up -d --build`
- [ ] `upgrade.sh <proj> <tag>`: fetch --tags; verify tag via ls-remote;
      `find upstream/<proj> -type d -name opc -prune -exec rm -rf {} +`;
      checkout; `git add upstream/<proj>`; prepare; build+up the component's
      services (map: buzz→buzz-keys buzz buzz-bootstrap frontdoor,
      hermes→hermes, paperclip→paperclip, tencentdb→tencentdb-core bootstrap
      hub proxy)
- [ ] `test-connectivity.sh`: source .env; per-container `docker inspect`
      healthy/running; curl probes with expected status sets; frontdoor→relay
      via `docker compose exec -T frontdoor buzz channels list`; exit 1 on
      any FAIL

### Task 3: compose + env

**Files:** Modify `docker-compose.yml`, `.env.example`

- [ ] `name: ${COMPOSE_PROJECT_NAME:-opc}`; 9× `image: ${IMAGE_PREFIX:-opc}/…`;
      8× `context: ./upstream/…`
- [ ] `.env.example`: add IMAGE_PREFIX=opc, COMPOSE_PROJECT_NAME=opc;
      BUZZ_RELAY_URL=ws://localhost:3000 + LAN-IP comment
- [ ] `docker compose config -q` clean

### Task 4: docs

**Files:** Rewrite `AGENTS.md`, `SETUP.md`; create design+plan docs

- [ ] AGENTS.md: upstream/patches/scripts map, invariants (patch-only,
      submodule rule), corrected paperclip tag
- [ ] SETUP.md: portable quickstart, upgrade section, setup pages,
      corrected tag table

### Task 5: fresh-clone verification

**Files:** none (test artifacts in /tmp)

- [ ] `git add` + initial commit in opc-stack
- [ ] `git clone /home/noah/opc-stack /tmp/opc-portable-test`
- [ ] `git -C /tmp/opc-portable-test submodule update --init` (clones all 4)
- [ ] copy real `.env` into the clone; `scripts/setup.sh`
- [ ] `scripts/test-connectivity.sh` → all PASS
- [ ] confirm frontdoor register loop: `docker logs frontdoor` shows
      "profile published" / joined channel on next channel creation
- [ ] final commit (gitlink already recorded)
