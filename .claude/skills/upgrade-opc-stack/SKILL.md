---
name: upgrade-opc-stack
description: >
  Use when upgrading a component of the OPC stack (buzz, hermes, paperclip,
  tencentdb) to a new upstream tag — when the user asks to upgrade/升版/bump
  a component or submodule tag, mentions scripts/upgrade.sh, release upgrades,
  or asks whether a version change is safe. Also use when the user asks about
  backing up the stack's volumes before an upgrade. Runs risk assessment,
  volume backup, gated upgrade, verification, and rollback for the compose
  stack in this repo. Not for fresh installs (setup.sh) or recovery after
  `docker compose down -v`.
---

# Upgrade OPC Stack Component

## Overview

`scripts/upgrade.sh <proj> <tag>` is the engine: fetch → verify tag →
checkout → re-apply patches → rebuild → redeploy. It performs NO risk
analysis, NO backup, NO verification gate, NO rollback. For Hermes, the
engine also aligns the Hermes tag baked into the Buzz frontdoor, rebuilds
`frontdoor` plus `hermes`, and recreates `frontdoor`, `hermes`, and
`hermes-dashboard` together. This skill is the safety layer around it. The
flow is a fixed recipe with two approval gates — follow it in order, never
skip a step to "be quick".

Data is precious and migrations are often one-way: the backup is
unconditional, not risk-gated. Skip it only if the user explicitly overrides
after being told the consequence.

## When to use / not

- Use: user wants to upgrade buzz/hermes/paperclip/tencentdb to a new tag;
  user asks "is this version bump safe"; user asks whether/what to back up
  before an upgrade.
- Not: fresh install (`scripts/setup.sh`), `down -v` recovery, non-tag
  changes to the stack. If the user only wants a risk report (no execution),
  do steps 1–2 and stop.

## Workflow (fixed order, two gates)

Submodule paths: `upstream/<proj>` is correct for buzz/hermes/paperclip, but
**tencentdb lives at `upstream/tencentdb-agent-memory`** (and its proxy
context at `upstream/tencentdb-agent-memory/MemoryProxy`). Use the real path
in every git reference — both `-C` targets AND `git add <path>` arguments
(`upstream/tencentdb` does not exist). `scripts/upgrade.sh` maps this for
you (SUBMODULE table); if you see `git -C upstream/tencentdb` anywhere, it
is the bug the map fixes.

1. **Sanity** — `.env` exists; `docker compose ps` reachable (if docker is
   unavailable, substitute compose-file inspection and note it); submodule at
   a known tag (`git -C upstream/<proj> describe --tags --always`).
2. **Risk assessment** (read-only; see checklist below) → produce the risk
   report (template below).
3. **GATE A — approval.** Present the report; do NOT back up or touch the
   stack until the user approves the upgrade path. If they only asked for an
   assessment, stop here.
4. **Backup** — run the bundled script:
   `bash .claude/skills/upgrade-opc-stack/scripts/backup-volumes.sh <proj> "backups/<proj>-<old>-<new>-$(date +%Y%m%dT%H%M%S)" <old> <new>`
   This stops the component's services, tars each stateful volume into
   `<backup-dir>`, writes `meta.txt` + `manifest.sha256`, and leaves the
   component STOPPED. For Hermes this includes `hermes-data`,
   `hermes-profiles`, and `frontdoor-hermes`, and stops `hermes`,
   `hermes-dashboard`, and `frontdoor`.
5. **Upgrade** — `scripts/upgrade.sh <proj> <tag>` (the Hermes path also
   aligns the frontdoor's baked Hermes tag; do not edit `upstream/` directly).
6. **Verify** — `tests/connectivity.sh` + component smoke checks +
   logs scan (see references/risk-checklist.md §6). Hermes verification must
   cover the gateway, dashboard, frontdoor ACP path, profile list, config
   migration, and one agent run.
7. **GATE B — on verification failure:** present the failure to the user and
   OFFER rollback; do NOT auto-rollback. For Hermes, restore the old Hermes
   tag and matching `patches/buzz/Dockerfile` frontdoor pin, restore all three
   Hermes-related volumes while services are stopped, rebuild `frontdoor`
   and `hermes`, then recreate `frontdoor hermes hermes-dashboard` and
   re-verify:
   ```bash
   git -C upstream/hermes checkout <old>
   sed -i -E 's|(git clone --depth 1 --branch )v[0-9.]+|\1<old>|' patches/buzz/Dockerfile
   git add upstream/hermes patches/buzz/Dockerfile
   scripts/prepare.sh
   bash .claude/skills/upgrade-opc-stack/scripts/restore-volumes.sh hermes backups/<backup-dir>
   docker compose build frontdoor hermes
   docker compose up -d --force-recreate frontdoor hermes hermes-dashboard
   tests/connectivity.sh
   ```
   For other components, restore = checkout old tag (record the gitlink),
   restore volumes from the backup, rebuild, re-verify.
8. **Finish** — report outcome, backup location, and the upgrade record
   (submodule pointer commit). Keep the backup dir until the new version has
   run clean for a while; prune old ones deliberately.

## Risk assessment checklist (all read-only)

Run every item; record findings in the report. Per-component data (tag
schemes, volume map, patch dependency surfaces, pitfalls) is in
`references/risk-checklist.md` — read it first.

1. **Tag exists** — `git -C upstream/<proj> ls-remote --tags origin "refs/tags/<tag>" "refs/tags/<tag>^{}" | grep -q .`
2. **Delta classification** — old vs new per the component's tag scheme;
   patch/minor/major or unknown. Unknown and prerelease targets default high.
3. **Changelog** — `git -C upstream/<proj> log --oneline <old>..<tag>`;
   grep for `migrat|break|schema|config|deprecat|env|api` — but commit
   subjects are often Chinese (tencentdb) so the grep is a hint, not a gate.
   ALWAYS read CHANGELOG.md at the new tag (if present) and scan the diff
   content for risk keywords.
4. **Migrations & data impact** — name scan
   (`git diff --name-only <old>..<tag> | grep -iE 'migrat|schema'`) misses
   in-code migrations; ALSO scan diff content:
   `git -C upstream/<proj> diff <old>..<tag> | grep -icE 'migrat|ALTER TABLE|CREATE TABLE|WAL|checkpoint'`
   and check the data-dir layout (e.g. `TDAI_DATA_DIR`) is unchanged.
5. **Patch compatibility** — derive each patched Dockerfile's build inputs,
   diff those paths `<old>..<tag>`, verify they still exist at `<tag>`
   (method in risk-checklist.md §3). Overlap or missing path = patch needs
   edits before rebuilding.
6. **Config drift** — compose env for the component vs the new tag's config
   docs/example; new required envs or renamed keys → .env/compose change.
7. **Couplings** — check risk-checklist.md §5 (e.g. buzz frontdoor bakes a
   hermes version; hermes API contract feeds paperclip).
8. **Backup plan** — state the volumes from the volume map; backup is
   unconditional for stateful volumes regardless of risk level.

## Risk report template (use exactly this shape)

```markdown
# Upgrade risk report: <proj> <old> → <new>
1. Verdict: RISK LEVEL (low|medium|high) + one-line justification
2. Delta: classification, N commits, files changed
3. Changelog highlights (breaking/migration/config-relevant only)
4. Migration & data impact: which volumes' data is touched
5. Patch compatibility: per patched Dockerfile — changed inputs? paths exist? edits needed?
6. Config drift: env/compose changes required (or none)
7. Backup plan: volumes to back up, target dir
8. Verification plan: connectivity + component smoke + data spot-checks
9. Risks & mitigations table
```

## Common mistakes

- Skipping the report or the approval gate — the point of the skill.
- Backing up while containers are running — postgres/sqlite tars must be of
  stopped volumes; `backup-volumes.sh` handles this, don't hand-roll tars
  against live containers.
- Restoring volumes over a running stack — restore only after stopping.
- Forgetting the frontdoor bakes its own Hermes — `scripts/upgrade.sh hermes`
  now aligns that pin and rebuilds the frontdoor by default.
- Confusing `patches/` keys (`tencentdb-agent-memory`, `.../MemoryProxy`)
  with upgrade.sh component keys (`tencentdb`) when checking patch paths.
- Editing `upstream/` directly — all customization goes through `patches/`.
- `docker compose down -v` anywhere in this flow — it destroys all volumes.
