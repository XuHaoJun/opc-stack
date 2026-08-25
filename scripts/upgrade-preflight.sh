#!/usr/bin/env bash
# Read-only pre-flight for an upstream tag bump.
#   scripts/upgrade-preflight.sh <buzz|hermes|paperclip|tencentdb> <tag>
#
# Every mechanical probe the upgrade needs, run by a machine instead of
# remembered by whoever is doing the upgrade. That distinction is the whole
# point: the one check that would have caught the tencentdb v2.0.1 overlay
# clobber existed only as a line in a checklist document, and a line in a
# document is not a check.
#
# Touches nothing: no checkout, no ref update, no container, no volume. The
# only network use is `git fetch --tags` on the submodule.
#
# Exit codes (the skill and scripts/upgrade.sh both branch on these):
#   0  nothing needs a human decision — the upgrade is mechanical
#   1  findings that need a human decision before proceeding
#   2  cannot report (unknown component, missing submodule, tag not on origin)
set -uo pipefail
cd "$(dirname "$0")/.."

PROJ="${1:-}"
TAG="${2:-}"
if [ -z "$PROJ" ] || [ -z "$TAG" ]; then
  echo "usage: scripts/upgrade-preflight.sh <buzz|hermes|paperclip|tencentdb> <tag>" >&2
  exit 2
fi

# Component → submodule directory. tencentdb's submodule is NOT named after
# the component; same mismatch prepare.sh and upgrade.sh already handle.
declare -A SUBMODULE=(
  [buzz]=buzz
  [hermes]=hermes
  [paperclip]=paperclip
  [tencentdb]=tencentdb-agent-memory
)
# Build inputs each patched Dockerfile consumes. Drift here means the patch
# itself may need edits before the rebuild — see references/risk-checklist.md §3.
declare -A PATCH_INPUTS=(
  [buzz]="Cargo.toml crates web admin-web package.json pnpm-lock.yaml pnpm-workspace.yaml patches migrations"
  [hermes]="pyproject.toml uv.lock package.json web ui-tui apps/shared plugins docker scripts"
  [paperclip]="package.json pnpm-lock.yaml scripts/docker-entrypoint.sh server ui packages/db"
  [tencentdb]="MemoryCore MemoryProxy MemoryPanel MemoryKnowledge deploy/panel-knowledge-combined"
)
# The upstream files our patched Dockerfiles/entrypoints were ADAPTED FROM.
# Higher signal than the input list above: a change here means our copy may be
# stale in a way rsync cannot tell us about, because patches/ overwrites rather
# than merges. This is the same shape as the whole-file schema overlay that
# silently reverted upstream's additions — just at Dockerfile level.
declare -A ADAPTED_FROM=(
  [buzz]="Dockerfile"
  [hermes]="Dockerfile docker/stage2-hook.sh docker/entrypoint-dispatch.sh"
  [paperclip]="Dockerfile scripts/docker-entrypoint.sh"
  [tencentdb]="MemoryCore/Dockerfile MemoryProxy/Dockerfile deploy/panel-knowledge-combined/Dockerfile deploy/panel-knowledge-combined/start-combined.sh"
)

if [ -z "${SUBMODULE[$PROJ]:-}" ]; then
  echo "unknown component '$PROJ' (pick from: ${!SUBMODULE[*]})" >&2
  exit 2
fi
UP="upstream/${SUBMODULE[$PROJ]}"
[ -d "$UP/.git" ] || [ -f "$UP/.git" ] || {
  echo "missing submodule $UP — run 'git submodule update --init' first" >&2
  exit 2
}

FINDINGS=0
finding() { FINDINGS=$((FINDINGS + 1)); printf '  ! %s\n' "$1"; }
note()    { printf '    %s\n' "$1"; }
section() { printf '\n── %s ──\n' "$1"; }

git -C "$UP" fetch origin --tags --prune --quiet 2>/dev/null || \
  note "warning: fetch failed; probes run against the local object store only"

if ! git -C "$UP" rev-parse -q --verify "refs/tags/$TAG^{commit}" >/dev/null 2>&1; then
  echo "tag '$TAG' not found in $UP (after fetch)" >&2
  exit 2
fi

# The pin is what a tag POINTS AT, not what `git describe` invents: describe
# reports buzz as `mobile-v0.11.0-rc.2-22-g…`, which is not a tag anybody set.
OLD="$(git -C "$UP" tag --points-at HEAD 2>/dev/null | head -1)"
[ -n "$OLD" ] || OLD="$(git -C "$UP" rev-parse --short HEAD)"

printf '── upgrade preflight: %s %s → %s ──\n' "$PROJ" "$OLD" "$TAG"

# ── delta ───────────────────────────────────────────────────────────────
section "delta"
COMMITS="$(git -C "$UP" rev-list --count "$OLD..$TAG" 2>/dev/null || echo '?')"
FILES="$(git -C "$UP" diff --name-only "$OLD..$TAG" 2>/dev/null | wc -l | tr -d ' ')"
note "$COMMITS commits, $FILES files changed"
case "$TAG" in
  *-beta*|*-rc*|*canary*|*-alpha*)
    finding "target is a PRERELEASE tag ($TAG) — default risk is high" ;;
esac

# ── changelog / release notes ───────────────────────────────────────────
section "changelog"
notes_found=0
for cand in "CHANGELOG.md" "releases/${TAG}.md" "releases/${TAG#v}.md"; do
  if git -C "$UP" cat-file -e "$TAG:$cand" 2>/dev/null; then
    note "found $cand"
    notes_found=1
    guide="$(git -C "$UP" show "$TAG:$cand" 2>/dev/null | \
      grep -A8 -iE '^#+ *(upgrade|breaking|migration|迁移|升级)' | head -30)"
    [ -n "$guide" ] && printf '%s\n' "$guide" | sed 's/^/    │ /'
  fi
done
[ "$notes_found" = 1 ] || note "no CHANGELOG.md or releases/<tag>.md at $TAG"
# A repo that documents upgrades per release and then ships a tag WITHOUT one
# has withdrawn the only assurance we rely on ("migrations run automatically,
# no manual action required"). Absence of the note is the finding, not proof
# that nothing is needed.
if git -C "$UP" ls-tree -d --name-only "$TAG" -- releases 2>/dev/null | grep -q .; then
  addednotes="$(git -C "$UP" diff --name-status "$OLD..$TAG" -- releases/ 2>/dev/null | \
    awk '$1 == "A" {print $2}')"
  if [ -n "$addednotes" ]; then
    note "release notes added in range:"
    printf '%s\n' "$addednotes" | sed 's/^/      /'
  else
    finding "upstream keeps releases/ notes but shipped NO note for $TAG — the usual \"no manual action required\" assurance is absent; read the commit log instead"
  fi
fi
# Subject grep is a HINT, never a gate: tencentdb's commit subjects are Chinese.
hits="$(git -C "$UP" log --oneline "$OLD..$TAG" 2>/dev/null | \
  grep -icE 'migrat|break|schema|config|deprecat|env |api ' || true)"
note "risk keywords in commit subjects: ${hits:-0} (hint only — subjects may not be English)"
dhits="$(git -C "$UP" diff "$OLD..$TAG" 2>/dev/null | \
  grep -icE 'ALTER TABLE|CREATE TABLE|DROP TABLE|migrat' || true)"
note "risk keywords in diff content: ${dhits:-0}"

# ── patch build inputs ──────────────────────────────────────────────────
section "patch build inputs"
changed_inputs=""
for path in ${PATCH_INPUTS[$PROJ]}; do
  if ! git -C "$UP" cat-file -e "$TAG:$path" 2>/dev/null && \
     ! git -C "$UP" ls-tree -d --name-only "$TAG" -- "$path" 2>/dev/null | grep -q .; then
    finding "build input GONE at $TAG: $path — the patched Dockerfile references it"
    continue
  fi
  if git -C "$UP" diff --quiet "$OLD..$TAG" -- "$path" 2>/dev/null; then :; else
    changed_inputs="$changed_inputs $path"
  fi
done
if [ -n "$changed_inputs" ]; then
  note "changed (review the patch against these):$changed_inputs"
else
  note "no patched build input changed"
fi

for src in ${ADAPTED_FROM[$PROJ]}; do
  if ! git -C "$UP" cat-file -e "$TAG:$src" 2>/dev/null; then
    finding "adapted-from source GONE at $TAG: $src — our patches/ copy has no upstream counterpart any more"
  elif git -C "$UP" diff --quiet "$OLD..$TAG" -- "$src" 2>/dev/null; then :; else
    finding "adapted-from source CHANGED at $TAG: $src — diff it against our copy in patches/ before rebuilding"
    note "      git -C $UP diff $OLD..$TAG -- $src"
  fi
done

# ── per-component probes ────────────────────────────────────────────────
section "component probes"
case "$PROJ" in

buzz)
  # sqlx embeds migrations at compile time and refuses to start when a
  # previously-applied migration is missing or its checksum moved. So the
  # only safe shape for a bump is "new files only".
  edited="$(git -C "$UP" diff --name-status "$OLD..$TAG" -- migrations/ 2>/dev/null | \
    awk '$1 != "A" {print $2}')"
  added="$(git -C "$UP" diff --name-status "$OLD..$TAG" -- migrations/ 2>/dev/null | \
    awk '$1 == "A"' | wc -l | tr -d ' ')"
  note "migrations added: $added"
  if [ -n "$edited" ]; then
    finding "existing migration files were MODIFIED — sqlx will hard-fail with VersionMismatch:"
    printf '%s\n' "$edited" | sed 's/^/      /'
  fi
  nt="$(git -C "$UP" diff "$OLD..$TAG" -- migrations/ 2>/dev/null | \
    grep -c '^+.*no-transaction' || true)"
  if [ "${nt:-0}" != 0 ]; then
    finding "new '-- no-transaction' migration(s): a mid-way failure leaves _sqlx_migrations dirty and needs manual repair"
  fi
  note "auto-apply: BUZZ_AUTO_MIGRATE is hard-coded true in docker-compose.yml (not .env-overridable)"
  ;;

paperclip)
  # Count .sql only. The directory also holds drizzle's meta/ snapshots, so an
  # unfiltered count reads high (18 "added" for 11 actual migrations) and the
  # number is used for judgement.
  added="$(git -C "$UP" diff --name-status "$OLD..$TAG" -- packages/db/src/migrations/ 2>/dev/null | \
    awk '$1 == "A" && $2 ~ /\.sql$/' | wc -l | tr -d ' ')"
  note "migrations added: $added (applied automatically on boot — the container is non-TTY)"
  # A modified .sql that has already been applied cannot be re-applied: drizzle
  # keys the journal by hash, so the change reaches no existing database and the
  # schema silently diverges between a fresh install and this one.
  pcedited="$(git -C "$UP" diff --name-status "$OLD..$TAG" -- packages/db/src/migrations/ 2>/dev/null | \
    awk '$1 != "A" && $2 ~ /\.sql$/ {print $2}')"
  if [ -n "$pcedited" ]; then
    finding "existing migration .sql files were MODIFIED — already-applied databases will never see the change:"
    printf '%s\n' "$pcedited" | sed 's/^/      /'
  fi
  drops="$(git -C "$UP" diff "$OLD..$TAG" -- packages/db/src/migrations/ 2>/dev/null | \
    grep -ciE '^\+.*(DROP TABLE|DROP COLUMN)' || true)"
  if [ "${drops:-0}" != 0 ]; then
    finding "destructive migration(s) ($drops DROP statements) — downgrade becomes impossible without the volume backup"
  fi
  ;;

hermes)
  newver="$(git -C "$UP" show "$TAG:hermes_cli/config_defaults.py" 2>/dev/null | \
    sed -n 's/.*"_config_version": *\([0-9]\+\).*/\1/p' | head -1)"
  ourver="$(sed -n 's/^OPC_CONFIG_VERSION=\([0-9]\+\).*/\1/p' \
    patches/hermes/hermes-entrypoint.sh 2>/dev/null | head -1)"
  note "seeded literal: ${ourver:-?} · upstream default at $TAG: ${newver:-?}"
  if [ -n "$newver" ] && [ -n "$ourver" ] && [ "$newver" != "$ourver" ]; then
    finding "_config_version drift — read these ladder steps, then bump the literal in BOTH entrypoints:"
    git -C "$UP" show "$TAG:hermes_cli/config_migrations.py" 2>/dev/null | \
      sed -n 's/^def \(_migrate_to_[0-9]\+\).*/\1/p' | \
      awk -v a="$ourver" '{ n = $0; sub(/_migrate_to_/, "", n); if (n + 0 > a + 0) print "      " $0 }'
  fi
  # tests/scientist.sh imports these PRIVATE functions and hermes-entrypoint.sh
  # mirrors their logic in shell. A rename breaks the gate in a way that reads
  # like a scientist-lane regression rather than an upgrade artifact.
  for fn in _read_container_argv _is_dashboard_container _strip_container_argv_prefix; do
    if ! git -C "$UP" show "$TAG:hermes_cli/container_boot.py" 2>/dev/null | grep -q "def $fn"; then
      finding "hermes_cli.container_boot.$fn is GONE at $TAG — tests/scientist.sh imports it and hermes-entrypoint.sh mirrors it"
    fi
  done
  if git -C "$UP" diff --quiet "$OLD..$TAG" -- hermes_cli/container_boot.py 2>/dev/null; then :; else
    finding "container_boot.py changed — re-read the two argv helpers and re-sync opc_is_dashboard_container in patches/hermes/hermes-entrypoint.sh"
  fi
  note "frontdoor bakes its own hermes checkout; upgrade.sh realigns patches/buzz/Dockerfile"
  ;;

tencentdb)
  # The overlay is a patch precisely so this probe can exist.
  pf="patches/tencentdb-agent-memory/MemoryCore/patches/v3-meta-schemas.patch"
  target="MemoryCore/src/metadata/router/v3-meta-schemas.ts"
  if [ -f "$pf" ]; then
    pf_abs="$PWD/$pf"
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/src/metadata/router"
    if git -C "$UP" show "$TAG:$target" > "$tmp/src/metadata/router/v3-meta-schemas.ts" 2>/dev/null; then
      if (cd "$tmp" && patch -p1 --fuzz=0 --dry-run --force < "$pf_abs" >/dev/null 2>&1); then
        note "v3-meta-schemas overlay patch applies cleanly at $TAG"
      else
        finding "v3-meta-schemas overlay patch does NOT apply at $TAG — regenerate it, or the build stops"
      fi
    else
      finding "$target is gone at $TAG — the overlay has no target any more"
    fi
    rm -rf "$tmp"
  else
    finding "overlay patch missing: $pf"
  fi
  if ! git -C "$UP" ls-tree -d --name-only "$TAG" -- deploy/panel-knowledge-combined | grep -q .; then
    finding "deploy/panel-knowledge-combined/ gone at $TAG — the hub image is built from it (upstream MemoryKnowledge/Dockerfile is broken)"
  fi
  # Session bindings are keyed on disk. A key-format change orphans every
  # existing binding, and they live in the nottl/ bucket the sweeper skips.
  if git -C "$UP" diff --quiet "$OLD..$TAG" -- \
      MemoryProxy/src/db/binding-repo.ts MemoryProxy/src/storage/key-utils.ts 2>/dev/null; then
    note "proxy session-binding key format unchanged"
  else
    finding "proxy session-binding key format CHANGED — existing bindings orphan (clients re-run sessionInit once) and are never swept from nottl/; plan to flush proxy_kv"
  fi
  envdiff="$(git -C "$UP" diff "$OLD..$TAG" -- MemoryCore/src/gateway/config.ts 2>/dev/null | \
    grep -cE '^[-+].*TDAI_' || true)"
  note "TDAI_* env surface changes in gateway/config.ts: ${envdiff:-0}"
  note "no sqlite version stamp exists (user_version=0 on all three DBs): a wrong-version boot is undetectable — the volume backup is the only guard"
  ;;
esac

# ── verdict ─────────────────────────────────────────────────────────────
section "verdict"
if [ "$FINDINGS" = 0 ]; then
  echo "  clean — nothing found that needs a human decision"
  echo
  echo "  next: scripts/upgrade.sh $PROJ $TAG"
  exit 0
fi
echo "  $FINDINGS finding(s) need a decision before upgrading"
echo
echo "  once reviewed and accepted:"
echo "    OPC_UPGRADE_ACK_FINDINGS=1 scripts/upgrade.sh $PROJ $TAG"
exit 1
