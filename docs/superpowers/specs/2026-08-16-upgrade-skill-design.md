# Upgrade Skill — Design

Date: 2026-08-16 · Status: approved (user picked: skill orchestrates upgrade.sh, repo-local placement, stop+tar backup, rollback on approval)

## Problem

`scripts/upgrade.sh <proj> <tag>` is a bare engine: fetch → verify tag →
checkout → re-apply patches → rebuild → redeploy. It performs zero risk
analysis before jumping tags, no data backup, no verification gate (the
`verify:` line is a comment), and no rollback. A bad upgrade (schema
migration, patch incompatibility, config drift) silently damages or
destroys state with no recovery path. User wants a skill that (a) checks
upgrade risk and (b) decides/executes volume backup — the reasoning layer
the script lacks.

## Facts verified before design

- 18 named volumes at the bottom of `docker-compose.yml`; component →
  service mapping exists only in `upgrade.sh`'s `SERVICES` table.
- No backup infra exists anywhere in the repo; `.gitignore` does not
  exclude `.claude/` → repo-local skill commits and travels.
- `patches/` keys differ from `upgrade.sh` component keys
  (`tencentdb-agent-memory`, `tencentdb-agent-memory/MemoryProxy` vs
  `tencentdb`) — risk checks must know both.
- Tag schemes per project: buzz `desktop-v0.5.14` (semver after prefix),
  hermes `v2026.8.13` (date-based, = v0.20.1 per AGENTS.md), paperclip
  `canary/v2026.722.1-canary.0`, tencentdb `v2.0.0`.
- SETUP.md "Upgrading a component" documents the manual flow and the
  patch-edit warning; the skill supersedes this.
- `docker compose stop` per service keeps other components running; volume
  tars of stopped containers preserve exact data-dir format → same-format
  rollback works even across postgres image changes.

## Decisions

1. **Skill orchestrates; `upgrade.sh` stays the engine** — unchanged.
   The skill adds: risk gate → approval gate → backup → verify →
   rollback-on-approval. Location: `.claude/skills/upgrade-opc-stack/`,
   committed to the repo (user chose repo-local over global).
2. **Backup = stop component services → tar stateful volumes → host dir.**
   Skip regenerable caches (`*-nix`, `*-omp`). Stateful set:
   `buzz-pgdata` `buzz-git` `buzz-redisdata` `buzz-miniodata`
   `hermes-data` `frontdoor-hermes` `paperclip-data`
   `tencentdb-core-data` `tencentdb-hub-data` `tencentdb-proxy-data`
   `opc-keys` (identity-critical, tiny — cheap insurance).
   Backup dir: `backups/<proj>-<old>→<new>-<ts>/`, sha256 manifest,
   `backups/` added to `.gitignore`.
3. **Backup is unconditional for stateful volumes** (user rejected
   risk-gated backup) — risk level gates scrutiny, not the backup.
4. **Risk assessment is read-only LLM judgment** (stays in SKILL.md body):
   delta classification per tag scheme (unparseable → assume major),
   changelog scan (`git log --oneline <old>..<tag>` + CHANGELOG.md at new
   tag, migration/breaking/deprecat/config keywords), **patch compat**:
   `git diff --stat <old>..<tag> -- <files patches/<proj> touches>` +
   verify files patches expect still exist at new tag (e.g. tencentdb
   `MemoryKnowledge` upstream-Dockerfile workaround), migration presence.
   Output: risk report (level + findings + config-drift spot-checks).
5. **Rollback offered, not automatic** (user choice): verification failure
   → present → wait for approval → checkout old tag → restore tars
   (down → untar → up) → rebuild → re-verify. Backup kept regardless.
6. **Deterministic mechanics in bundled scripts**
   (`scripts/backup-volumes.sh`, `scripts/restore-volumes.sh`), volume map
   static in `references/risk-checklist.md` (same class as `SERVICES`
   table; no bash YAML parsing).
7. **Evals run in dry-run/safe modes** — real upgrades mutate the live
   stack, so test cases: (a) risk report on a hypothetical tag (read-only),
   (b) backup/restore round-trip on a scratch volume, (c) full flow
   dry-run. Baseline = same prompts without skill.

## Files

- Created: `.claude/skills/upgrade-opc-stack/SKILL.md`,
  `.claude/skills/upgrade-opc-stack/scripts/{backup-volumes,restore-volumes}.sh`,
  `.claude/skills/upgrade-opc-stack/references/risk-checklist.md`
- Modified: `.gitignore` (`backups/`), `scripts/upgrade.sh` (fix: tencentdb
  submodule path map — `upstream/tencentdb` does not exist; eval surfaced it)
- Docs: SETUP.md upgrade section re-pointed at the skill

## Verification

- `bash -n` on both scripts; backup/restore round-trip on a scratch volume
  (create volume → seed file → backup → wipe → restore → content matches).
- Risk assessment run against current pinned tags (hermes v2026.8.13 →
  hypothetical v2026.9.1): produces a report with real changelog/patch
  findings, zero repo mutation.
- Full flow dry-run: no submodule checkout, no volume writes, no build.
