# OPC Stack Upgrade — Per-Component Data

Source of truth for `upgrade-opc-stack` skill checks. Keep in sync when
`docker-compose.yml` / `patches/` / `scripts/upgrade.sh` change.

## 1. Volume map (compose project name prefix: `${COMPOSE_PROJECT_NAME:-opc}_`)

| Component | Stateful (back up) | Regenerable (never back up) |
|---|---|---|
| buzz | `buzz-pgdata` `buzz-redisdata` `buzz-miniodata` `buzz-git` `frontdoor-hermes` `opc-keys` | `buzz-nix` `buzz-omp` `frontdoor-nix` `frontdoor-omp` |
| hermes | `hermes-data` `hermes-profiles` `frontdoor-hermes` | `hermes-nix` `hermes-omp` |
| paperclip | `paperclip-data` | `paperclip-nix` |
| tencentdb | `tencentdb-core-data` `tencentdb-hub-data` `tencentdb-proxy-data` | — |

Rationale: `*-nix` stores are caches (seeded at boot, self-heal, wipable via
`docker volume rm`); `*-omp` is omp client state. Hermes includes
`frontdoor-hermes` because the Hermes upgrade also updates the Buzz frontdoor's
baked Hermes ACP runtime. `opc-keys` is relay identity — irreplaceable, tiny,
cheap insurance on every buzz upgrade.

Services that must be STOPPED for a consistent backup (volume owners +
dependents; `docker compose stop` also stops dependencies):

| Component | Services |
|---|---|
| buzz | `buzz-db buzz-redis buzz-minio buzz-minio-init buzz-keys buzz buzz-bootstrap frontdoor` |
| hermes | `hermes hermes-dashboard frontdoor` |
| paperclip | `paperclip` |
| tencentdb | `tencentdb-core tencentdb-bootstrap tencentdb-hub tencentdb-proxy` |

## 2. Tag schemes & delta classification

| Component | Scheme | Classification |
|---|---|---|
| buzz | `desktop-vX.Y.Z` | strip `desktop-v` → semver |
| hermes | `vYYYY.M.D` (date) | date-based; check embedded version (`pyproject.toml` at tag) |
| paperclip | `vYYYY.MDD.N` stable, `canary/…-canary.K` prerelease | canary = pre-release |
| tencentdb | `vX.Y.Z[-beta.N]` | semver + prerelease |

Current pins are NOT listed here. Every version this table used to carry went
stale. `scripts/outdated.sh` derives them (and `scripts/upgrade-preflight.sh`
reports the specific old→new delta).

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
- **hermes** — `scripts/upgrade.sh hermes <tag>` aligns the Hermes tag in
  `patches/buzz/Dockerfile`, rebuilds `frontdoor` plus `hermes`, and recreates
  `frontdoor`, `hermes`, and `hermes-dashboard` together. Its backup must
  include `hermes-data`, `hermes-profiles`, and `frontdoor-hermes`.
  `tests/scientist.sh` reaches INTO hermes internals and will break on an
  upgrade that moves them, with a red gate that looks like a scientist-lane
  regression rather than an upgrade artifact. Three couplings, all in that one
  script: it imports the PRIVATE functions
  `hermes_cli.container_boot._read_container_argv` (lines 252-296 at
  `v2026.8.16`) and `_is_dashboard_container` (353-371; the helper they share,
  `_strip_container_argv_prefix`, is 298-342), and it invokes them through the
  hard-coded interpreter path `/opt/hermes/.venv/bin/python3`. A rename, a
  signature change, or a venv relocation breaks the "dashboard container argv
  resolves to dashboard role" row. `patches/hermes/hermes-entrypoint.sh`'s own
  `opc_is_dashboard_container` MIRRORS that upstream logic in shell — re-read
  the upstream functions after the bump and re-sync the shell copy, or the
  gateway/dashboard two-writer race on `hermes-profiles` comes back (its
  symptom is an s6-log restart storm on
  `logs/gateways/<profile>/lock`, not a failing test).
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
  Core sqlite migrates online and one-way (`ALTER TABLE ADD COLUMN`, and an FTS5
  DROP+rebuild because FTS5 cannot add columns) — backup is mandatory. Three
  corrections to what this file used to claim, all measured 2026-08-25:
  * **There is no version stamp anywhere.** `PRAGMA user_version` is 0 on
    `vectors.db`, `metadata.db` and `knowledge.db`; "which schema is this"
    is decided by probing for columns. A wrong-version boot is undetectable,
    which is why the volume backup is the only real guard.
  * **`metadata.db` migrates LAZILY**, on the first `/v3/meta/*` request
    (`server.ts:413` → `factory.ts:255` → `sqlite-adapter.ts:96-106`), not at
    boot. Nothing has migrated until something calls it; our
    `tencentdb-bootstrap` one-shot is what triggers it.
  * **Migration failure is a silent degraded no-op**, not a crash
    (`sqlite.ts:518-527` sets `degraded = true`; `store-pool.ts:216-218` only
    warns). The symptom is "memories stop being written and the panel empties",
    never a container that fails to start.
  The proxy session-binding key format change
  (`spaceId:userId:agentSource:sessionId` → `spaceId:sessionId`) is **ahead of
  us, not behind us** — it lands in `v2.0.1`, with no dual-read and no backfill.
  Orphaned bindings live under the `nottl/` prefix, which the sweeper never
  scans (`storage/factory.ts:296-311`), so they are permanent litter. Clients
  re-run `sessionInit` once. `scripts/upgrade-preflight.sh tencentdb <tag>`
  diffs `binding-repo.ts` + `key-utils.ts` and reports this.
  * The `v3-meta-schemas.ts` OPC overlay is applied as a **patch**, not a file
    copy, precisely so an upstream edit stops the build. A frozen copy would
    revert upstream's own additions silently — at `v2.0.1` it would have
    removed `userCreateWithKeySchema` while the router still bound it (lazy
    deref → one route 500s, 53 others fine) and dropped
    `fixedAssetListWithDetail.asset_types` (zod strips unknown keys, so the
    filter merely stops filtering).
- **nix (all)** — `/nix` volumes seeded at boot + self-heal; add tools with
  `nix profile add` (deprecated `install` clobbers the profile).

## 5. Cross-component couplings

- `scripts/upgrade.sh hermes <tag>` aligns the Hermes tag baked into the Buzz
  frontdoor and rebuilds it by default. Upgrading Hermes therefore touches
  `frontdoor-hermes` as well as the gateway/dashboard volumes.
- Paperclip agents route models through the hermes gateway
  (`apiBaseUrl: http://hermes:8642`); hermes upgrades must keep the API server
  contract (`/v1`, OpenAI-compatible) or paperclip agents break.
- LLM key is shared through the single canonical `OPENAI_API_KEY` contract. Hermes
  custom-provider runtime also consumes `OPENAI_BASE_URL`; shared
  gateway/dashboard/Paperclip/TencentDB models use `OPENAI_MODEL`, while the
  frontdoor relay model uses `BUZZ_AGENT_MODEL`. Model selection is persisted in
  editable `config.yaml`. None of the four upgrades should require .env changes
  unless a new version needs new env vars (config-drift check).

## 6. Post-upgrade verification (per component)

`scripts/upgrade.sh` runs **`tests/migrations.sh <proj>`** itself and fails the
upgrade if it does not pass — that gate is the one that asks whether the
migration actually happened, rather than whether the container is up. Every
silent upgrade failure this stack has hit left `connectivity.sh` green, so
health is necessary but proves nothing on its own.

All: `tests/migrations.sh <proj>` (run automatically) + `tests/connectivity.sh`
(container health + HTTP probes + frontdoor→relay link) +
`docker compose logs --since 10m <svc>` scanned for
`error|panic|fatal|migration`.

| Component | Data-level smoke |
|---|---|
| buzz | relay `/_readiness`; `frontdoor` channels list; old chat history visible; git web GUI loads; media in minio intact |
| hermes | dashboard 200/401; API `/docs`; profiles listed; frontdoor ACP path; model/provider config intact (config.yaml regenerated — verify kanban still off); run one agent session |
| paperclip | `/api/health`; login; agents list (hermes-gateway adapter intact); tasks readable |
| tencentdb | core `/health`; panel login with `TENCENTDB_ADMIN_USER_KEY`; existing memories/skills/wiki visible; knowledge `/docs`; proxy `/`; one L0 write + recall via proxy; session re-bind if binding format changed |

## 7. Rollback

**The three components fail differently on a downgrade, and only one of them
tells you.** This is why the volume backup is unconditional rather than
risk-gated:

| Component | What happens if you just put the old image back |
|---|---|
| buzz | **Hard fail, loudly.** sqlx's `Migrator` runs with `ignore_missing = false` and validates applied migrations at startup; a row it does not recognise is `VersionMissing` and the relay exits → crash loop. You cannot boot the old version against a migrated DB. Restore `buzz-pgdata` first. |
| paperclip | **Silent.** Drizzle ships no down migrations and computes pending as `available − applied`, so a downgrade reports `upToDate` and the old server runs against the newer schema. If the range contained a destructive migration (e.g. `0196_drop_cloud_upstream_tables.sql`), the old code queries tables that no longer exist. Restore `paperclip-data` (or one of the hourly dumps under `instances/default/data/backups`). |
| tencentdb | **Undetectable.** No version stamp exists (§4), so nothing compares anything. The old binary opens the newer DB and behaves as if it were fine. Restore all three volumes. |
| hermes | config.yaml has already been migrated in place by the boot hook; the old code reads a newer `_config_version`. Restore `hermes-data`, `hermes-profiles` and `frontdoor-hermes` together. |


Restore = checkout old tag and matching frontdoor pin → replace all Hermes
related volume contents from backup → rebuild `frontdoor` and `hermes` →
recreate `frontdoor hermes hermes-dashboard` → re-verify. The backup tar is a
same-format data-dir snapshot — restoring it before booting the old version
rolls back any one-way migration the new version ran.
