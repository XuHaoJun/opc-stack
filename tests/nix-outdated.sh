#!/bin/sh
# Exercise scripts/nix-outdated.sh against fake git/curl/docker commands.
#
# The fixture is fully offline. It verifies that the report compares the
# declarative seed pins with the nixpkgs channel and the live root profile,
# without invoking any mutating nix profile operation.
set -eu
cd "$(dirname "$0")/.."

fail() { echo "FAIL  $1" >&2; exit 1; }
assert_grep() {
    label="$1"; pattern="$2"; file="$3"
    grep -qE "$pattern" "$file" || fail "$label: no match for /$pattern/ in:\n$(cat "$file")"
}
refute_grep() {
    label="$1"; pattern="$2"; file="$3"
    grep -qE "$pattern" "$file" && fail "$label: unexpected match for /$pattern/ in:\n$(cat "$file")"
    return 0
}

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/scripts" "$fixture/patches/nix-seed" "$fixture/data"
cp scripts/nix-outdated.sh "$fixture/scripts/nix-outdated.sh"
cp patches/nix-seed/Dockerfile "$fixture/patches/nix-seed/Dockerfile"
cp patches/nix-seed/opc-nix-daemon.sh "$fixture/patches/nix-seed/opc-nix-daemon.sh"
chmod +x "$fixture/scripts/nix-outdated.sh"

cat > "$fixture/bin/git" <<'SH'
#!/bin/sh
printf 'git %s\n' "$*" >> "${FAKE_LOG:?}"
case "$*" in
    *"refs/heads/"*)
        printf '%s\trefs/heads/%s\n' "${FAKE_NIXPKGS_HEAD:?}" "${FAKE_NIXPKGS_CHANNEL:-nixos-unstable}"
        exit 0
        ;;
esac
printf 'unexpected fake git call: %s\n' "$*" >&2
exit 2
SH

cat > "$fixture/bin/curl" <<'SH'
#!/bin/sh
printf 'curl %s\n' "$*" >> "${FAKE_LOG:?}"
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
    echo 'fake curl failure' >&2
    exit 22
fi
cat "${FAKE_DATA:?}/nix-release.json"
SH

cat > "$fixture/bin/docker" <<'SH'
#!/bin/sh
printf 'docker %s\n' "$*" >> "${FAKE_LOG:?}"
if [ "${FAKE_DOCKER_FAIL:-0}" = 1 ]; then
    echo 'fake docker failure' >&2
    exit 1
fi
case "$*" in
    *" --version")
        cat "${FAKE_DATA:?}/nix-version"
        ;;
    *" eval --json --expr "*)
        cat "${FAKE_DATA:?}/package-versions.json"
        ;;
    *" profile list --json "*)
        cat "${FAKE_DATA:?}/profile.json"
        ;;
    *)
        echo "unexpected fake docker call: $*" >&2
        exit 2
        ;;
esac
SH
chmod +x "$fixture/bin/git" "$fixture/bin/curl" "$fixture/bin/docker"

data="$fixture/data"
log="$fixture/calls"
pin='8be7bd0c83f1'
head_same="${pin}0000000000000000000000000000"
head_new='1234567890abcdef1234567890abcdef12345678'

cat > "$data/nix-release.json" <<'EOF'
[{"name":"2.35.2"}]
EOF
printf 'nix (Nix) 2.35.2\n' > "$data/nix-version"

# The profile contains every declared seed attr at the same pinned URL, plus
# Nix itself, which is installed by the Nix installer rather than nixpkgs.
jq -n --arg pin "$pin" '
  {elements: ((["ripgrep","jq","fd","htop","bat","just","mise","gh","procps","iproute2","lsof","postgresql","valkey"]
    | map({key: ., value: {originalUrl: ("github:NixOS/nixpkgs/" + $pin)}})
    | from_entries)
    + {nix: {originalUrl: ""}})}
' > "$data/profile.json"

write_package_versions() {
    current="$1"
    latest="$2"
    jq -n --arg current "$current" --arg latest "$latest" '
      {
        ripgrep:{current:"15.2.0",latest:"15.2.0"},
        jq:{current:"1.8.2",latest:"1.8.2"},
        fd:{current:"10.4.2",latest:"10.4.2"},
        htop:{current:"3.5.2",latest:"3.5.2"},
        bat:{current:"0.26.1",latest:"0.26.1"},
        just:{current:"1.58.0",latest:"1.58.0"},
        mise:{current:"2026.8.3",latest:"2026.8.3"},
        gh:{current:"2.97.0",latest:"2.97.0"},
        procps:{current:"4.0.6",latest:"4.0.6"},
        iproute2:{current:"7.1.0",latest:"7.1.0"},
        lsof:{current:"4.99.7",latest:"4.99.7"},
        postgresql:{current:$current,latest:$latest},
        valkey:{current:"9.1.1",latest:"9.1.1"}
      }
    ' > "$data/package-versions.json"
}
write_package_versions 18.4 18.4

run() {
    rc=0
    FAKE_DATA="$data" FAKE_LOG="$log" FAKE_NIXPKGS_HEAD="${FAKE_NIXPKGS_HEAD:-}" \
        FAKE_NIXPKGS_CHANNEL=nixos-unstable PATH="$fixture/bin:$PATH" \
        "$fixture/scripts/nix-outdated.sh" "$@" >"$fixture/out" 2>&1 || rc=$?
}

# ── current channel, release, and live profile are clean ─────────────────────
: > "$log"
FAKE_NIXPKGS_HEAD="$head_same" run
[ "$rc" -eq 0 ] || fail "clean Nix report should exit 0, got $rc: $(cat "$fixture/out")"
assert_grep "nix current row" '^nix +2\.35\.2 +2\.35\.2 +-$' "$fixture/out"
assert_grep "nixpkgs current row" '^nixpkgs +8be7bd0c83f1 +8be7bd0c83f1 +-$' "$fixture/out"
assert_grep "postgresql current row" '^postgresql +18\.4 +18\.4 +-$' "$fixture/out"
assert_grep "profile aligned" 'live root profile matches seed pin' "$fixture/out"
refute_grep "no mutating profile command" 'profile (add|remove|upgrade)' "$log"
assert_grep "Nix tags endpoint" 'api.github.com/repos/NixOS/nix/tags' "$log"

# ── newer channel and Nix release produce actionable status 1 ────────────────
cat > "$data/nix-release.json" <<'EOF'
[{"name":"2.36.0"}]
EOF
write_package_versions 18.4 18.6
: > "$log"
FAKE_NIXPKGS_HEAD="$head_new" run
[ "$rc" -eq 1 ] || fail "new Nix inputs should exit 1, got $rc: $(cat "$fixture/out")"
assert_grep "nix upgrade row" '^nix +2\.35\.2 +2\.36\.0 +newer$' "$fixture/out"
assert_grep "nixpkgs upgrade row" '^nixpkgs +8be7bd0c83f1 +1234567890abcdef1234567890abcdef12345678 +newer$' "$fixture/out"
assert_grep "postgresql upgrade row" '^postgresql +18\.4 +18\.6 +newer$' "$fixture/out"
assert_grep "runtime-first guidance" 'upgrade the live root profile first' "$fixture/out"
refute_grep "still no mutating profile command" 'profile (add|remove|upgrade)' "$log"

# ── a tested runtime that has not been copied back to the seed is disclosed ──
jq -n --arg pin "$head_new" '
  {elements: ((["ripgrep","jq","fd","htop","bat","just","mise","gh","procps","iproute2","lsof","postgresql","valkey"]
    | map({key: ., value: {originalUrl: ("github:NixOS/nixpkgs/" + $pin)}})
    | from_entries)
    + {nix: {originalUrl: ""}})}
' > "$data/profile.json"
cat > "$data/nix-release.json" <<'EOF'
[{"name":"2.35.2"}]
EOF
: > "$log"
FAKE_NIXPKGS_HEAD="$head_new" run
[ "$rc" -eq 1 ] || fail "runtime/seed drift should exit 1, got $rc: $(cat "$fixture/out")"
assert_grep "runtime seed drift" 'live root profile differs from seed pin' "$fixture/out"
assert_grep "seed update guidance" 'copy the tested pin into patches/nix-seed' "$fixture/out"

# Restore the clean profile for the remaining structural cases.
jq -n --arg pin "$pin" '
  {elements: ((["ripgrep","jq","fd","htop","bat","just","mise","gh","procps","iproute2","lsof","postgresql","valkey"]
    | map({key: ., value: {originalUrl: ("github:NixOS/nixpkgs/" + $pin)}})
    | from_entries)
    + {nix: {originalUrl: ""}})}
' > "$data/profile.json"
# ── the Nix executable can drift independently of the package profile ────────
printf 'nix (Nix) 2.36.0\n' > "$data/nix-version"
: > "$log"
FAKE_NIXPKGS_HEAD="$head_same" run
[ "$rc" -eq 1 ] || fail "live Nix version drift should exit 1, got $rc: $(cat "$fixture/out")"
assert_grep "live Nix drift row" '^live-nix +2\.36\.0 +2\.35\.2 +drift$' "$fixture/out"
assert_grep "live Nix drift warning" 'live Nix runtime is 2\.36\.0 but the seed pins 2\.35\.2' "$fixture/out"
printf 'nix (Nix) 2.35.2\n' > "$data/nix-version"


# ── source pin disagreement is incomplete, not an upgrade verdict ────────────
sed -i 's/NIXPKGS=github:NixOS\/nixpkgs\/8be7bd0c83f1/NIXPKGS=github:NixOS\/nixpkgs\/deadbeefdead/' \
    "$fixture/patches/nix-seed/opc-nix-daemon.sh"
: > "$log"
FAKE_NIXPKGS_HEAD="$head_same" run --skip-runtime
[ "$rc" -eq 2 ] || fail "pin drift should exit 2, got $rc: $(cat "$fixture/out")"
assert_grep "pin drift warning" 'Dockerfile and daemon nixpkgs pins differ' "$fixture/out"

# ── an unavailable runtime is reported as incomplete, never as clean ─────────
sed -i 's/NIXPKGS=github:NixOS\/nixpkgs\/deadbeefdead/NIXPKGS=github:NixOS\/nixpkgs\/8be7bd0c83f1/' \
    "$fixture/patches/nix-seed/opc-nix-daemon.sh"
: > "$log"
FAKE_DOCKER_FAIL=1 FAKE_NIXPKGS_HEAD="$head_same" run
[ "$rc" -eq 2 ] || fail "unavailable runtime should exit 2, got $rc: $(cat "$fixture/out")"
assert_grep "runtime unavailable warning" 'could not inspect live Nix runtime' "$fixture/out"

# ── static mode remains usable without a live stack ──────────────────────────
: > "$log"
FAKE_DOCKER_FAIL=1 FAKE_NIXPKGS_HEAD="$head_same" run --skip-runtime
assert_grep "static mode disclosure" 'live root profile check skipped' "$fixture/out"
assert_grep "static package disclosure" '^postgresql +- +- +skipped$' "$fixture/out"
refute_grep "static mode does not invoke docker" '^docker ' "$log"

# ── usage ────────────────────────────────────────────────────────────────────
run --unknown
[ "$rc" -eq 2 ] || fail "unknown option should exit 2"
assert_grep "usage" 'usage: scripts/nix-outdated\.sh' "$fixture/out"

echo "PASS  Nix seed/runtime outdated report"
echo "PASS  Nix report is read-only and handles degraded runtime"
