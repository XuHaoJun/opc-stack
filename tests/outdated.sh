#!/bin/sh
# Exercise scripts/outdated.sh against a fake git, fully offline.
#
# The production script runs in a temporary fixture root with a fake `git` on
# PATH, so this never touches the real submodules, the network, or any object
# store. Tag lists live in $FAKE_DATA/<submodule>.tags, the pinned tag in
# <submodule>.pin, the release date in <submodule>.date — a missing .tags file
# makes the fake `git ls-remote` fail the way an unreachable origin does.
set -eu
cd "$(dirname "$0")/.."

fail() { echo "FAIL  $1" >&2; exit 1; }
assert_grep() {
    label="$1"; pattern="$2"; file="$3"
    grep -qE "$pattern" "$file" || fail "$label: no match for /$pattern/ in:
$(cat "$file")"
}
refute_grep() {
    label="$1"; pattern="$2"; file="$3"
    grep -qE "$pattern" "$file" && fail "$label: unexpected match for /$pattern/ in:
$(cat "$file")"
    return 0
}
# Run the script under test; records the exit status in $rc instead of aborting.
run() {
    rc=0
    FAKE_DATA="$data" FAKE_LOG="$fixture/calls" PATH="$fixture/bin:$PATH" \
        "$fixture/scripts/outdated.sh" "$@" >"$fixture/out" 2>&1 || rc=$?
}

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
data="$fixture/data"
mkdir -p "$fixture/bin" "$fixture/scripts" "$fixture/patches/buzz" "$data" \
    "$fixture/upstream/buzz" "$fixture/upstream/hermes" \
    "$fixture/upstream/paperclip" "$fixture/upstream/tencentdb-agent-memory"
cp scripts/outdated.sh "$fixture/scripts/outdated.sh"
chmod +x "$fixture/scripts/outdated.sh"

cat > "$fixture/bin/git" <<'SH'
#!/bin/sh
printf 'git %s\n' "$*" >> "$FAKE_LOG"
dir=.
while [ $# -gt 0 ]; do
    case "$1" in
        -C) dir="$2"; shift 2 ;;
        *) break ;;
    esac
done
name="$(basename "$dir")"
cmd="${1:-}"
case "$cmd" in
    tag)
        [ -f "$FAKE_DATA/$name.pin" ] && cat "$FAKE_DATA/$name.pin"
        exit 0 ;;
    ls-remote)
        [ -f "$FAKE_DATA/$name.tags" ] || { echo "fatal: unreachable" >&2; exit 128; }
        awk 'NF { printf "%040d\trefs/tags/%s\n", NR, $0 }' "$FAKE_DATA/$name.tags"
        exit 0 ;;
    log)
        [ -f "$FAKE_DATA/$name.date" ] && cat "$FAKE_DATA/$name.date"
        exit 0 ;;
    fetch) exit 0 ;;
esac
exit 0
SH
chmod +x "$fixture/bin/git"

# ── fixture pins + tag universes ─────────────────────────────────────────────
# buzz: 4 stable releases behind, with the traps that make this script exist —
# a newer rc, a newer tag in a DIFFERENT family (mobile-/desktop/), and 0.5.9,
# which is lexically greater than 0.5.18 but semantically older.
printf 'desktop-v0.5.14\n' > "$data/buzz.pin"
cat > "$data/buzz.tags" <<'EOF'
desktop-v0.5.9
desktop-v0.5.14
desktop-v0.5.15
desktop-v0.5.16
desktop-v0.5.17
desktop-v0.5.18
desktop-v0.5.19-rc.1
desktop/v0.5.20-rc1
mobile-v0.11.0
mobile-v0.11.0-rc.2
v0.5.99
sprout-desktop-latest
EOF
printf '2026-08-22\n' > "$data/buzz.date"

# hermes: current. v2026.8.16.2 proves a 4-component hotfix stays eligible
# under a 3-component pin (it is older here, so it must not become "latest").
printf 'v2026.8.19\n' > "$data/hermes.pin"
cat > "$data/hermes.tags" <<'EOF'
v2026.8.3
v2026.8.13
v2026.8.16
v2026.8.16.2
v2026.8.18
v2026.8.19
premerge-oh-god
backup/precopystrip-1-2
EOF
printf '2026-08-21\n' > "$data/hermes.date"

# paperclip: 1 behind, inside a 1000-tag canary swamp plus legacy v0.3.x tags
# that must not be counted as "behind".
printf 'v2026.817.0\n' > "$data/paperclip.pin"
cat > "$data/paperclip.tags" <<'EOF'
v0.3.0
v0.3.1
v2026.722.0
v2026.817.0
v2026.824.0
canary/v2026.824.1-canary.0
nightly/v2026.825.0-nightly.0
@paperclipai/adapter-claude-local@0.3.1
paperclipai@0.3.1
EOF
printf '2026-08-24\n' > "$data/paperclip.date"

# tencentdb: 1 behind, with a newer beta that must be ignored.
printf 'v2.0.0\n' > "$data/tencentdb-agent-memory.pin"
cat > "$data/tencentdb-agent-memory.tags" <<'EOF'
v0.3.6
v1.0.1
v2.0.0
v2.0.0-beta.1
v2.0.1
v2.0.1-beta.2
EOF
printf '2026-08-05\n' > "$data/tencentdb-agent-memory.date"

frontdoor_pin() {
    printf '%s\n' \
        "RUN git clone --depth 1 --branch $1 \\" \
        '    https://github.com/NousResearch/hermes-agent.git /opt/hermes-src' \
        > "$fixture/patches/buzz/Dockerfile"
}
frontdoor_pin v2026.8.19

# ── the full report ──────────────────────────────────────────────────────────
run
[ "$rc" -eq 1 ] || fail "outdated stack should exit 1, got $rc: $(cat "$fixture/out")"
assert_grep "buzz row"      '^buzz +desktop-v0\.5\.14 +desktop-v0\.5\.18 +4 +2026-08-22$' "$fixture/out"
assert_grep "hermes row"    '^hermes +v2026\.8\.19 +v2026\.8\.19 +- +2026-08-21$'         "$fixture/out"
assert_grep "paperclip row" '^paperclip +v2026\.817\.0 +v2026\.824\.0 +1 +2026-08-24$'   "$fixture/out"
assert_grep "tencentdb row" '^tencentdb +v2\.0\.0 +v2\.0\.1 +1 +2026-08-05$'             "$fixture/out"
assert_grep "summary"       '3 of 4 components have newer stable tags' "$fixture/out"
assert_grep "buzz cmd"      'scripts/upgrade\.sh buzz +desktop-v0\.5\.18' "$fixture/out"
assert_grep "paperclip cmd" 'scripts/upgrade\.sh paperclip +v2026\.824\.0' "$fixture/out"
assert_grep "tencentdb cmd" 'scripts/upgrade\.sh tencentdb +v2\.0\.1' "$fixture/out"
refute_grep "no upgrade line for a current component" 'upgrade\.sh hermes' "$fixture/out"
refute_grep "no pre-release candidate" '\-(rc|canary|beta|nightly)[.0-9]|/v0\.5\.20-rc1' "$fixture/out"
refute_grep "no cross-family candidate" '(mobile-v|v0\.5\.99|desktop/v)' "$fixture/out"
# Reporting must never touch the checkout, and must not fetch objects it has.
refute_grep "read-only: no checkout" ' checkout ' "$fixture/calls"
refute_grep "read-only: no fetch when the object is local" ' fetch ' "$fixture/calls"

# ── component filter, all current ────────────────────────────────────────────
run hermes
[ "$rc" -eq 0 ] || fail "current component should exit 0, got $rc: $(cat "$fixture/out")"
assert_grep "single-component summary" 'newest stable tag' "$fixture/out"
refute_grep "filtered out" '^buzz ' "$fixture/out"

# ── missing release date degrades to '?', not to a failure ───────────────────
rm "$data/tencentdb-agent-memory.date"
run tencentdb
[ "$rc" -eq 1 ] || fail "dateless outdated component should still exit 1, got $rc"
assert_grep "unknown date" '^tencentdb +v2\.0\.0 +v2\.0\.1 +1 +\?$' "$fixture/out"
assert_grep "date fallback fetches one tag" 'fetch --depth 1 --no-tags' "$fixture/calls"
printf '2026-08-05\n' > "$data/tencentdb-agent-memory.date"

# ── untagged HEAD: report the gap, exit 2 ────────────────────────────────────
: > "$data/buzz.pin"
run buzz
[ "$rc" -eq 2 ] || fail "untagged submodule should exit 2, got $rc: $(cat "$fixture/out")"
assert_grep "untagged row" '^buzz +\? +\? +\? +\?$' "$fixture/out"
assert_grep "untagged reason" 'not on a tag' "$fixture/out"
printf 'desktop-v0.5.14\n' > "$data/buzz.pin"

# ── multiple tags at HEAD: highest parseable one wins, and says so ───────────
printf 'desktop-v0.5.14\nsprout-desktop-latest\ndesktop-v0.5.13\n' > "$data/buzz.pin"
run buzz
[ "$rc" -eq 1 ] || fail "multi-tag HEAD should still report, got $rc: $(cat "$fixture/out")"
assert_grep "multi-tag pick" '^buzz +desktop-v0\.5\.14 +desktop-v0\.5\.18 +4' "$fixture/out"
assert_grep "multi-tag disclosure" 'more than one tag' "$fixture/out"
printf 'desktop-v0.5.14\n' > "$data/buzz.pin"

# ── unreachable origin: partial report, exit 2 ───────────────────────────────
mv "$data/paperclip.tags" "$data/paperclip.tags.off"
run
[ "$rc" -eq 2 ] || fail "unreachable origin should exit 2, got $rc: $(cat "$fixture/out")"
assert_grep "failed row" '^paperclip +v2026\.817\.0 +\? +\? +\?$' "$fixture/out"
assert_grep "failed reason" 'could not list tags' "$fixture/out"
assert_grep "other components still reported" '^buzz +desktop-v0\.5\.14 +desktop-v0\.5\.18' "$fixture/out"
mv "$data/paperclip.tags.off" "$data/paperclip.tags"

# ── no stable tag in the pinned family (e.g. a canary pin) ───────────────────
printf 'canary/v2026.824.1-canary.0\n' > "$data/paperclip.pin"
run paperclip
[ "$rc" -eq 2 ] || fail "pin with no stable family should exit 2, got $rc: $(cat "$fixture/out")"
assert_grep "empty family reason" "no stable tags in family" "$fixture/out"
printf 'v2026.817.0\n' > "$data/paperclip.pin"

# ── hermes' second pin (patches/buzz/Dockerfile) must agree ──────────────────
frontdoor_pin v2026.8.13
run hermes
[ "$rc" -eq 2 ] || fail "frontdoor pin drift should exit 2, got $rc: $(cat "$fixture/out")"
assert_grep "drift names both pins" 'v2026\.8\.13.*v2026\.8\.19|v2026\.8\.19.*v2026\.8\.13' "$fixture/out"
assert_grep "drift names the file" 'patches/buzz/Dockerfile' "$fixture/out"

printf '%s\n' 'FROM scratch' > "$fixture/patches/buzz/Dockerfile"
run hermes
[ "$rc" -eq 2 ] || fail "unreadable frontdoor pin should exit 2, got $rc: $(cat "$fixture/out")"
frontdoor_pin v2026.8.19
run hermes
[ "$rc" -eq 0 ] || fail "aligned pins should exit 0, got $rc: $(cat "$fixture/out")"

# ── usage errors ─────────────────────────────────────────────────────────────
run nodalis
[ "$rc" -eq 2 ] || fail "unknown component should exit 2, got $rc"
assert_grep "usage" 'usage: scripts/outdated\.sh' "$fixture/out"

echo "PASS  upstream outdated report"
echo "PASS  stable-family inference (rc/canary/beta/nightly, cross-family, version order)"
echo "PASS  degraded paths (no date, untagged, unreachable, empty family, pin drift)"
