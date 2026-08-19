# OPC Stack Upgrade — Per-Component Data

Source of truth for `upgrade-opc-stack` skill checks. Keep in sync when
`docker-compose.yml` / `patches/` / `scripts/upgrade.sh` change.

## 1. Volume map (compose project name prefix: `${COMPOSE_PROJECT_NAME:-opc}_`)

| Component | Stateful (back up) | Regenerable (never back up) |
|---|---|---|
| buzz | `buzz-pgdata` `buzz-redisdata` `buzz-miniodata` `buzz-git` `frontdoor-hermes` `opc-keys` | `buzz-nix` `buzz-omp` `frontdoor-nix` `frontdoor-omp` |
| hermes | `hermes-data` | `hermes-nix` `hermes-omp` |
| paperclip | `paperclip-data` | `paperclip-nix` |
| tencentdb | `tencentdb-core-data` `tencentdb-hub-data` `tencentdb-proxy-data` | — |

Rationale: `*-nix` stores are caches (seeded at boot, self-heal, wipable via
`docker volume rm`); `*-omp` is omp client state. `opc-keys` is relay
identity — irreplaceable, tiny, cheap insurance on every buzz upgrade.

Services that must be STOPPED for a consistent backup (volume owners +
dependents; `docker compose stop` also stops dependencies):

| Component | Services |
|---|---|
| buzz | `buzz-db buzz-redis buzz-minio buzz-minio-init buzz-keys buzz buzz-bootstrap frontdoor` |
| hermes | `hermes` |
| paperclip | `paperclip` |
| tencentdb | `tencentdb-core tencentdb-bootstrap tencentdb-hub tencentdb-proxy` |

## 2. Tag schemes & delta classification

| Component | Scheme | Example (current) | Classification |
|---|---|---|---|
| buzz | `desktop-vX.Y.Z` | `desktop-v0.5.14` | strip `desktop-v` → semver |
| hermes | `vYYYY.M.D` (date) | `v2026.8.16` (= v0.20.2) | date-based; check embedded version (`pyproject.toml` at tag) |
| paperclip | `canary/vYYYY.MDD.N-canary.K` or stable `v…` | `canary/v2026.722.1-canary.0` | canary = pre-release |
| tencentdb | `vX.Y.Z[-beta.N]` | `v2.0.0` | semver + prerelease |

Rules: patch bump → LOW risk. Minor bump → MEDIUM. Major bump, unparseable
scheme, date-based with unknown embedded version, or prerelease target
(`-beta`, `canary`) → HIGH unless analysis shows otherwise. Any upgrade that
touches data → backup is unconditional regardless of level.

## 3. Patch dependency surfaces (diff targets `<old>..<tag>`)

`scripts/prepare.sh` rsyncs `patches/<proj>/` → `upstream/<proj>/opc/`.
The patched Dockerfiles build from repo-root or subdir contexts — diff these
upstream paths to detect patch breakage:

| Component | Build context | Paths the patched Dockerfiles COPY/build (diff these) |
|---|---|---|
| buzz | `upstream/buzz` root | cargo workspace (`Cargo.toml`, `crates/`), `web/`, `admin-web/`, `package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `patches/` (upstream's own pnpm patches) |
| buzz frontdoor | same image | **bakes `hermes-agent` from GitHub tag** (`git clone --branch <tag>` in Dockerfile) — the baked hermes version only changes when the patch is edited, NOT when hermes submodule upgrades |
| hermes | `upstream/hermes` root | `pyproject.toml`, `uv.lock`, `package.json`, `web/`, `ui-tui/`, `apps/shared/`, `plugins/`, `docker/` (s6-rc.d, cont-init.d, shims, entrypoint-dispatch.sh) |
| paperclip | `upstream/paperclip` root | pnpm workspace (`package.json`, `pnpm-lock.yaml`, `packages/**/package.json`), `scripts/docker-entrypoint.sh`, `server/`, `ui/` |
| tencentdb hub | `upstream/tencentdb-agent-memory` root | `MemoryPanel/`, `MemoryKnowledge/`, `deploy/panel-knowledge-combined/start-combined.sh` |
| tencentdb proxy | `upstream/tencentdb-agent-memory/MemoryProxy` | `package.json`, `packages/`, absence of `packages/cost-guard` (upstream public tag omits it; patch stubs it) |

Method: for each patched Dockerfile, list its COPY/build inputs; then
`git -C upstream/<proj> diff --stat <old>..<tag> -- <paths>` (changed →
review patch) and `git -C upstream/<proj> ls-tree -r --name-only <tag> -- <paths>`
(still exists?). Diff targets are read from the Dockerfiles at run time, not
memorized — this table is the starting hint list.

## 4. Per-component pitfalls & invariants

- **buzz** — one canonical host = one community (schema UNIQUE + NIP-42/98).
  Upgrading the tag does not change the host; but never let a migration
  rewrite relay identity (`opc-keys`). `BUZZ_AUTO_MIGRATE=true` — schema
  migrations run automatically on boot; check new migrations in the diff.
  After a fresh-volume rebuild the community is NEW → re-run add-member
  (`buzz-bootstrap` one-shot handles it on first boot).
- **hermes** — Kanban must stay OFF (`agent.disabled_toolsets: [kanban]` +
  dispatcher off in the seeded config.yaml; Paperclip is the only work
  plane). New versions may change config schema → verify the entrypoint's
  seeded config still parses and still disables kanban. PyPI `hermes-agent`
  lags the git tag (0.19.0 vs 0.20.1): installs are editable-from-git-tag.
- **paperclip** — `pi_local` adapter is incompatible with omp v17; agents
  use `claude_local` + `engine:"acp"` + `agentCommand:"omp acp --yolo"`.
  Production image installs `claude-code@latest codex@latest opencode-ai
  gemini-cli@latest` — these float; a paperclip bump can pull new CLI
  versions. Verify the ACP handshake after upgrade (`acp-smoke-test.mjs` in
  the paperclip container).
- **tencentdb** — upstream `MemoryKnowledge/Dockerfile` is broken; hub uses
  `deploy/panel-knowledge-combined` (verify still present at new tag).
  Core sqlite migrates online, one-way (ADD COLUMN / FTS rebuild) — backup
  is mandatory. Proxy session-binding key format has changed between
  versions before (spaceId:userId:agentSource:sessionId → spaceId:sessionId);
  old bindings orphaned → clients re-run sessionInit once. `TDAI_*` env
  interface has been byte-identical across 2.0.x so far — verify, don't assume.
- **nix (all)** — `/nix` volumes seeded at boot + self-heal; add tools with
  `nix profile add` (deprecated `install` clobbers the profile).

## 5. Cross-component couplings

- **buzz frontdoor bakes a hermes version.** Upgrading hermes does NOT
  update the frontdoor's baked agent; the frontdoor keeps the old one until
  `patches/buzz/Dockerfile`'s `git clone --branch` is edited and buzz rebuilt.
  Decide per upgrade whether that mismatch matters (frontdoor runs `hermes
  acp` for relay conversations).
- Paperclip agents route models through the hermes gateway
  (`apiBaseUrl: http://hermes:8642`); hermes upgrades must keep the API
  server contract (`/v1`, OpenAI-compatible) or paperclip agents break.
- LLM key is shared through the single canonical `OPENAI_API_KEY` contract. Hermes
  custom-provider runtime also consumes `OPENAI_BASE_URL`; shared
  gateway/dashboard/Paperclip/TencentDB models use `OPENAI_MODEL`, while the
  frontdoor relay model uses `BUZZ_AGENT_MODEL`. Model selection is persisted in
  editable `config.yaml`. None of the four upgrades should require .env changes
  unless a new version needs new env vars (config-drift check).

## 6. Post-upgrade verification (per component)

All: `scripts/test-connectivity.sh` (container health + HTTP probes +
frontdoor→relay link) + `docker compose logs --since 10m <svc>` scanned for
`error|panic|fatal|migration`.

| Component | Data-level smoke |
|---|---|
| buzz | relay `/_readiness`; `frontdoor` channels list; old chat history visible; git web GUI loads; media in minio intact |
| hermes | dashboard 200/401; API `/docs`; profiles listed; model/provider config intact (config.yaml regenerated — verify kanban still off); run one agent session |
| paperclip | `/api/health`; login; agents list (hermes-gateway adapter intact); tasks readable |
| tencentdb | core `/health`; panel login with `TENCENTDB_ADMIN_USER_KEY`; existing memories/skills/wiki visible; knowledge `/docs`; proxy `/`; one L0 write + recall via proxy; session re-bind if binding format changed |

## 7. Rollback

Restore = checkout old tag → replace volume contents from backup → rebuild.
Concrete: `scripts/upgrade.sh <proj> <old-tag>` (reuses the engine), then
`restore-volumes.sh <proj> <backup-dir>`, then `docker compose up -d
<services>`, then re-verify. The backup tar is a same-format data-dir
snapshot — restoring it before booting the old version rolls back any
one-way migration the new version ran.
