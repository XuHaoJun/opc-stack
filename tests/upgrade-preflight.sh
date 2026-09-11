#!/bin/sh
# Exercise scripts/upgrade-preflight.sh against real git fixture repos.
#
# Offline: the fixtures are actual git repos built in a temp dir, with no
# `origin` remote, so the script's `git fetch` fails and it falls back to the
# local object store — a path worth covering anyway. Nothing touches the real
# checkout, images, containers or volumes.
#
# Each case pins one behaviour that has to hold for the upgrade path to be
# trustworthy: a clean bump must be silent, and each class of trouble must be
# LOUD rather than merely mentioned in a document.
set -eu
cd "$(dirname "$0")/.."

REPO_ROOT="$PWD"
fx="$(mktemp -d)"
trap 'rm -rf "$fx"' EXIT

fail() { echo "FAIL  $1" >&2; exit 1; }

# run <component> <tag> → stdout in $OUT, exit code in $RC
run() {
    set +e
    OUT="$(cd "$fx" && ./scripts/upgrade-preflight.sh "$1" "$2" 2>&1)"
    RC=$?
    set -e
}
expect_rc() {
    [ "$RC" = "$1" ] || fail "$2: expected exit $1, got $RC
$OUT"
}
expect_out() {
    printf '%s' "$OUT" | grep -qF "$1" || fail "$2: missing from report: $1
$OUT"
}
expect_no_out() {
    printf '%s' "$OUT" | grep -qF "$1" && fail "$2: should not have reported: $1
$OUT"
    return 0
}

git_init() { # git_init <dir>
    mkdir -p "$1"
    git -C "$1" init -q
    git -C "$1" config user.email t@t; git -C "$1" config user.name t
}
git_tag() { # git_tag <dir> <tag>
    git -C "$1" add -A
    git -C "$1" commit -qm "$2"
    git -C "$1" tag "$2"
}

mkdir -p "$fx/scripts" "$fx/patches/hermes" "$fx/patches/buzz"
cp "$REPO_ROOT/scripts/upgrade-preflight.sh" "$fx/scripts/upgrade-preflight.sh"
chmod +x "$fx/scripts/upgrade-preflight.sh"

# ── unusable inputs report exit 2, never a verdict ──────────────────────
run nosuch v1.0.0
expect_rc 2 "unknown component"
mkdir -p "$fx/upstream"
run buzz v1.0.0
expect_rc 2 "missing submodule"

# ── buzz: additions-only is clean; an edited migration is a hard finding ──
b="$fx/upstream/buzz"
git_init "$b"
mkdir -p "$b/migrations"
printf 'CREATE TABLE a();\n' > "$b/migrations/0001_a.sql"
printf 'FROM scratch\n' > "$b/Dockerfile"
# Every path the preflight's PATCH_INPUTS table names for buzz: a fixture that
# omits one produces a "build input GONE" finding, which is the check working.
for f in Cargo.toml package.json pnpm-lock.yaml pnpm-workspace.yaml; do
    printf 'x\n' > "$b/$f"
done
for d in crates web admin-web patches; do
    mkdir -p "$b/$d"; printf 'x\n' > "$b/$d/keep"
done
# The memory-ingress overlay (patches/buzz/patches/opc-memory-ingress-meta.patch) is
# dry-run against the NEW tag and its three buzz-acp anchors are checked, so the
# fixture carries both halves — same shape as the tencentdb overlay case below. A
# fixture without them makes every buzz case report "anchor GONE", which is the check
# working on a repo that simply is not buzz.
mkdir -p "$b/crates/buzz-acp/src"
cat > "$b/crates/buzz-acp/src/queue.rs" <<'EOF'
pub fn format_prompt(batch: &FlushBatch) -> Vec<String> {
    let mut blocks = Vec::new();
    blocks.push(render_events(batch));
    blocks
}
EOF
printf 'fn session_prompt_blocks_with_idle_timeout() {}\n' > "$b/crates/buzz-acp/src/pool.rs"
printf 'fn build_prompt_params() {}\n' > "$b/crates/buzz-acp/src/acp.rs"
git_tag "$b" v1.0.0
printf 'CREATE TABLE b();\n' > "$b/migrations/0002_b.sql"
git_tag "$b" v1.1.0
mkdir -p "$fx/patches/buzz/patches"
cat > "$fx/patches/buzz/patches/opc-memory-ingress-meta.patch" <<'EOF'
--- a/crates/buzz-acp/src/queue.rs
+++ b/crates/buzz-acp/src/queue.rs
@@ -1,5 +1,6 @@
 pub fn format_prompt(batch: &FlushBatch) -> Vec<String> {
     let mut blocks = Vec::new();
+    blocks.push(memory_events_meta(batch));
     blocks.push(render_events(batch));
     blocks
 }
EOF

git -C "$b" checkout -q v1.0.0
run buzz v1.1.0
expect_rc 0 "buzz additions-only"
expect_out "migrations added: 1" "buzz additions-only"

git -C "$b" checkout -q master 2>/dev/null || git -C "$b" checkout -q main
printf 'CREATE TABLE a2();\n' > "$b/migrations/0001_a.sql"
git_tag "$b" v1.2.0
git -C "$b" checkout -q v1.0.0
run buzz v1.2.0
expect_rc 1 "buzz edited migration"
expect_out "were MODIFIED" "buzz edited migration"

# A renamed buzz-acp anchor breaks the overlay, and the build only finds out during
# `docker compose build` — the preflight has to say so first.
git -C "$b" checkout -q master 2>/dev/null || git -C "$b" checkout -q main
git -C "$b" checkout -q v1.0.0 -- migrations/0001_a.sql
sed -i 's/pub fn format_prompt(/pub fn render_prompt(/' "$b/crates/buzz-acp/src/queue.rs"
git_tag "$b" v1.3.0
git -C "$b" checkout -q v1.0.0
run buzz v1.3.0
expect_rc 1 "buzz-acp anchor renamed"
expect_out "anchor GONE at v1.3.0: pub fn format_prompt(" "buzz-acp anchor renamed"
expect_out "does NOT apply" "buzz-acp anchor renamed"

# ── hermes: _config_version drift names the exact ladder steps ───────────
h="$fx/upstream/hermes"
git_init "$h"
mkdir -p "$h/hermes_cli" "$h/docker"
cat > "$h/hermes_cli/config_defaults.py" <<'EOF'
DEFAULT_CONFIG = {
    "_config_version": 40,
}
EOF
cat > "$h/hermes_cli/config_migrations.py" <<'EOF'
def _migrate_to_40(results, quiet): pass
def _migrate_to_41(results, quiet): pass
EOF
cat > "$h/hermes_cli/container_boot.py" <<'EOF'
def _read_container_argv(): pass
def _strip_container_argv_prefix(): pass
def _is_dashboard_container(): pass
EOF
printf 'FROM scratch\n' > "$h/Dockerfile"
printf 'x\n' > "$h/docker/stage2-hook.sh"
printf 'x\n' > "$h/docker/entrypoint-dispatch.sh"
for f in pyproject.toml uv.lock package.json; do printf 'x\n' > "$h/$f"; done
for d in web ui-tui apps/shared plugins scripts; do
    mkdir -p "$h/$d"; printf 'x\n' > "$h/$d/keep"
done
# The ACP sidecar patch (patches/buzz/patches/hermes-acp-memory-ingress.patch) is
# applied to a hermes checkout whose tag scripts/upgrade.sh realigns to this one, so
# the preflight dry-runs it here. Every path it archives has to exist at the tag.
mkdir -p "$h/acp_adapter" "$h/agent"
cat > "$h/acp_adapter/content.py" <<'EOF'
def blocks_to_text(text_parts):
    return "\n".join(text_parts)
EOF
printf 'def _content_blocks_to_openai_user_content(): pass\n' > "$h/acp_adapter/server.py"
for f in agent/conversation_loop.py agent/memory_manager.py agent/turn_facade.py run_agent.py; do
    printf 'x\n' > "$h/$f"
done
mkdir -p "$fx/patches/buzz/patches"
cat > "$fx/patches/buzz/patches/hermes-acp-memory-ingress.patch" <<'EOF'
--- a/acp_adapter/content.py
+++ b/acp_adapter/content.py
@@ -1,2 +1,3 @@
 def blocks_to_text(text_parts):
+    # memory ingress: carry _meta alongside the joined text
     return "\n".join(text_parts)
EOF
git_tag "$h" v2026.1.1
printf 'OPC_CONFIG_VERSION=40\n' > "$fx/patches/hermes/hermes-entrypoint.sh"
run hermes v2026.1.1
expect_rc 0 "hermes aligned config version"
expect_out "seeded literal: 40" "hermes aligned config version"

sed -i 's/"_config_version": 40/"_config_version": 42/' "$h/hermes_cli/config_defaults.py"
cat >> "$h/hermes_cli/config_migrations.py" <<'EOF'
def _migrate_to_42(results, quiet): pass
EOF
git_tag "$h" v2026.2.2
git -C "$h" checkout -q v2026.1.1
run hermes v2026.2.2
expect_rc 1 "hermes config version drift"
expect_out "_config_version drift" "hermes config version drift"
expect_out "_migrate_to_41" "hermes config version drift"
expect_out "_migrate_to_42" "hermes config version drift"
expect_no_out "_migrate_to_40" "hermes config version drift"

# A renamed private helper breaks tests/scientist.sh and the shell mirror in
# hermes-entrypoint.sh, with a symptom that looks like a lane regression.
git -C "$h" checkout -q master 2>/dev/null || git -C "$h" checkout -q main
sed -i 's/def _is_dashboard_container/def _is_dash_container/' "$h/hermes_cli/container_boot.py"
git_tag "$h" v2026.3.3
git -C "$h" checkout -q v2026.1.1
run hermes v2026.3.3
expect_rc 1 "hermes renamed argv helper"
expect_out "_is_dashboard_container is GONE" "hermes renamed argv helper"

# The sidecar patch's own hunk context moving is the same class of trouble, and it
# lands on the frontdoor build rather than on the hermes image.
git -C "$h" checkout -q master 2>/dev/null || git -C "$h" checkout -q main
git -C "$h" checkout -q v2026.1.1 -- hermes_cli/container_boot.py hermes_cli/config_defaults.py
sed -i 's/def blocks_to_text(text_parts):/def blocks_to_text(text_parts, sep):/' "$h/acp_adapter/content.py"
git_tag "$h" v2026.4.4
git -C "$h" checkout -q v2026.1.1
run hermes v2026.4.4
expect_rc 1 "hermes sidecar patch context moved"
expect_out "ACP sidecar patch does NOT apply" "hermes sidecar patch context moved"

# ── tencentdb: the overlay patch must be dry-run against the NEW tag ─────
t="$fx/upstream/tencentdb-agent-memory"
git_init "$t"
mkdir -p "$t/MemoryCore/src/metadata/router" "$t/MemoryProxy/src/db" \
    "$t/MemoryProxy/src/storage" "$t/deploy/panel-knowledge-combined" \
    "$t/MemoryPanel" "$t/MemoryKnowledge" "$t/MemoryCore/src/gateway"
sch="$t/MemoryCore/src/metadata/router/v3-meta-schemas.ts"
cat > "$sch" <<'EOF'
// header
import { z } from "zod";

export const teamCreateSchema = z.object({
  name: nonEmpty,
  owner_user_id: nonEmpty,
});
EOF
printf 'x\n' > "$t/MemoryProxy/src/db/binding-repo.ts"
printf 'x\n' > "$t/MemoryProxy/src/storage/key-utils.ts"
printf 'x\n' > "$t/MemoryCore/src/gateway/config.ts"
printf 'FROM scratch\n' > "$t/MemoryCore/Dockerfile"
printf 'FROM scratch\n' > "$t/MemoryProxy/Dockerfile"
printf 'FROM scratch\n' > "$t/deploy/panel-knowledge-combined/Dockerfile"
printf 'x\n' > "$t/deploy/panel-knowledge-combined/start-combined.sh"
printf 'x\n' > "$t/MemoryPanel/keep"; printf 'x\n' > "$t/MemoryKnowledge/keep"
git_tag "$t" v1.0.0

mkdir -p "$fx/patches/tencentdb-agent-memory/MemoryCore/patches"
cat > "$fx/patches/tencentdb-agent-memory/MemoryCore/patches/v3-meta-schemas.patch" <<'EOF'
--- a/src/metadata/router/v3-meta-schemas.ts
+++ b/src/metadata/router/v3-meta-schemas.ts
@@ -3,5 +3,6 @@

 export const teamCreateSchema = z.object({
+  team_id: z.string().min(1).optional(),
   name: nonEmpty,
   owner_user_id: nonEmpty,
 });
EOF

# An upstream tag that only ADDS elsewhere: the patch still applies → clean.
cat >> "$sch" <<'EOF'

export const userCreateWithKeySchema = z.object({ username: nonEmpty });
EOF
git_tag "$t" v1.1.0
git -C "$t" checkout -q v1.0.0
run tencentdb v1.1.0
expect_rc 0 "tencentdb overlay still applies"
expect_out "overlay patch applies cleanly" "tencentdb overlay still applies"

# An upstream tag that edits the hunk context: the patch must NOT be guessed at.
git -C "$t" checkout -q master 2>/dev/null || git -C "$t" checkout -q main
sed -i 's/  name: nonEmpty,/  name: nonEmptyString,/' "$sch"
git_tag "$t" v1.2.0
git -C "$t" checkout -q v1.0.0
run tencentdb v1.2.0
expect_rc 1 "tencentdb overlay context moved"
expect_out "does NOT apply" "tencentdb overlay context moved"

# A session-binding key format change orphans every existing binding.
git -C "$t" checkout -q master 2>/dev/null || git -C "$t" checkout -q main
git -C "$t" checkout -q v1.0.0 -- "MemoryCore/src/metadata/router/v3-meta-schemas.ts"
printf 'flattened\n' > "$t/MemoryProxy/src/storage/key-utils.ts"
git_tag "$t" v1.3.0
git -C "$t" checkout -q v1.0.0
run tencentdb v1.3.0
expect_rc 1 "tencentdb binding format change"
expect_out "session-binding key format CHANGED" "tencentdb binding format change"

# The hub is built from deploy/panel-knowledge-combined because upstream's own
# MemoryKnowledge/Dockerfile is broken; losing it silently is unbuildable.
git -C "$t" checkout -q master 2>/dev/null || git -C "$t" checkout -q main
git -C "$t" rm -rq deploy/panel-knowledge-combined
git_tag "$t" v1.4.0
git -C "$t" checkout -q v1.0.0
run tencentdb v1.4.0
expect_rc 1 "tencentdb hub build context removed"
expect_out "deploy/panel-knowledge-combined/ gone" "tencentdb hub build context removed"

echo "PASS  preflight refuses to report on unusable input (exit 2)"
echo "PASS  buzz migration-set shape (additions clean, edits fatal)"
echo "PASS  hermes _config_version drift names the exact ladder steps"
echo "PASS  hermes private argv helpers tracked"
echo "PASS  tencentdb overlay patch dry-run against the target tag"
echo "PASS  tencentdb binding format + hub build context"
