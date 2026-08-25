#!/usr/bin/env bash
# Sync patches/<project>/ onto the submodule checkouts in upstream/.
# Idempotent: safe to run before every build.
#
# Why this exists: all local customizations (custom Dockerfiles, entrypoints,
# one-shot bootstrap scripts) live ONLY in patches/ (version-controlled here).
# patches/<proj>/ mirrors the contents of the opc/ dir the repos were
# customized with; prepare copies it onto upstream/<proj>/opc/. upstream/ is
# clean submodule checkouts — never edit them directly; upgrade = checkout a
# new tag (see scripts/upgrade.sh), then this re-applies.
set -euo pipefail
# Ignore SIGPIPE. `scripts/prepare.sh | head` or `| grep -q` closes stdout
# early, which under `set -e` kills the script PART WAY THROUGH THE SYNC — and
# the output printed so far looks like a normal, successful run. A half-synced
# tree then builds an image missing exactly the change you just made. (Cost:
# one confused debugging session over a skill that would not update.)
trap '' PIPE
cd "$(dirname "$0")/.."

apply_patch() {
  local proj="$1"    # path under upstream/, e.g. "buzz" or "tencentdb-agent-memory/MemoryProxy"
  local src="patches/$proj"
  local dst="upstream/$proj/opc"
  if [ ! -d "$src" ]; then
    echo "SKIP  $proj (no patch dir)"
    return
  fi
  if [ ! -d "upstream/$proj" ]; then
    echo "FAIL  $proj: upstream/$proj missing — run 'git submodule update --init' first"
    exit 1
  fi
  mkdir -p "$dst"
  rsync -a --delete "$src/" "$dst/"
  echo "SYNC  $proj → $dst"
}

# ── drift guard ─────────────────────────────────────────────────────────
# Some things exist in two copies BY DESIGN, because they must reach two
# different hermes homes (the Buzz front door and the gateway) and each home
# is served by a different image. "Keep these two files identical" is a rule
# that has silently broken three times in this repo, and the failure is
# invisible at runtime: work routes correctly from one surface and not the
# other, depending on where the user happened to type. Cheaper to fail here.
check_identical() {
  local label="$1" a="$2" b="$3"
  if [ ! -f "$a" ] || [ ! -f "$b" ]; then
    echo "FAIL  $label: expected two copies, missing $( [ -f "$a" ] || echo "$a" ) $( [ -f "$b" ] || echo "$b" )"
    exit 1
  fi
  if ! diff -q "$a" "$b" >/dev/null; then
    echo "FAIL  $label: the two copies have drifted — they must be byte-identical"
    diff -u "$a" "$b" | head -40
    exit 1
  fi
  echo "SAME  $label"
}

check_identical "paperclip-api skill" \
  patches/buzz/skills/paperclip-api/SKILL.md \
  patches/hermes/skills/paperclip-api/SKILL.md

check_identical "agent SOUL.md" \
  patches/buzz/SOUL.md \
  patches/hermes/SOUL.md

# Three copies here, same reasoning: every image sources the identical client
# wiring for the ONE shared nix store. A copy that drifts gets a different
# PATH order or a stale profile path, and the symptom is "the tool I installed
# is not there" in one container only — the least diagnosable shape there is.
check_identical "nix client seed (buzz/hermes)" \
  patches/buzz/nix-seed.sh \
  patches/hermes/nix-seed.sh
check_identical "nix client seed (hermes/paperclip)" \
  patches/hermes/nix-seed.sh \
  patches/paperclip/nix-seed.sh
check_identical "paperclip CLI (buzz/hermes)" \
  patches/buzz/opc-paperclip \
  patches/hermes/opc-paperclip

# ── hermes config schema version ────────────────────────────────────────
# Both hermes entrypoints seed a config.yaml stamped with OPC_CONFIG_VERSION.
# Hermes migrates that file IN PLACE on every container boot (its s6
# cont-init hook runs the same ladder `hermes update` runs), so a stamp that
# has fallen behind upstream's default means every clean install silently runs
# unreviewed migrations over our own template. That is not hypothetical: the
# ladder once removed agent.system_prompt from the front door's config, and the
# stack stayed green for 27 hours before a human noticed the agent had stopped
# filing tickets.
#
# The fix is not to track upstream automatically — it is to make the bump a
# decision somebody made. Read the steps named below, confirm they are no-ops
# (or handle them), then edit the constant in BOTH entrypoints.
check_config_version() {
  local defaults=upstream/hermes/hermes_cli/config_defaults.py
  if [ ! -f "$defaults" ]; then
    echo "SKIP  hermes _config_version (submodule not checked out)"
    return
  fi
  local want have_h have_f
  want="$(sed -n 's/.*"_config_version": *\([0-9]\+\).*/\1/p' "$defaults" | head -1)"
  have_h="$(sed -n 's/^OPC_CONFIG_VERSION=\([0-9]\+\).*/\1/p' patches/hermes/hermes-entrypoint.sh | head -1)"
  have_f="$(sed -n 's/^OPC_CONFIG_VERSION=\([0-9]\+\).*/\1/p' patches/buzz/frontdoor-entrypoint.sh | head -1)"
  if [ -z "$want" ]; then
    echo "FAIL  hermes _config_version: cannot read the default out of $defaults"
    exit 1
  fi
  if [ "$have_h" != "$have_f" ]; then
    echo "FAIL  hermes _config_version: the two entrypoints disagree (hermes=$have_h frontdoor=$have_f)"
    exit 1
  fi
  if [ "$have_h" != "$want" ]; then
    echo "FAIL  hermes _config_version drift: seeded $have_h, upstream default $want"
    echo "      Read these ladder steps before bumping — each one REWRITES the config"
    echo "      file we seed, and a step that touches a key we own is invisible at runtime:"
    sed -n "s/^def \(_migrate_to_[0-9]\+\).*/\1/p" upstream/hermes/hermes_cli/config_migrations.py \
      | awk -v a="$have_h" '{ n=$0; sub(/_migrate_to_/,"",n); if (n+0 > a+0) print "        " $0 }'
    echo "      Then set OPC_CONFIG_VERSION=$want in BOTH:"
    echo "        patches/hermes/hermes-entrypoint.sh"
    echo "        patches/buzz/frontdoor-entrypoint.sh"
    exit 1
  fi
  echo "SAME  hermes _config_version ($have_h, matches upstream default)"
}
check_config_version

apply_patch buzz
apply_patch hermes
apply_patch paperclip
apply_patch tencentdb-agent-memory
apply_patch tencentdb-agent-memory/MemoryProxy
apply_patch tencentdb-agent-memory/MemoryCore

echo "prepare: done"
