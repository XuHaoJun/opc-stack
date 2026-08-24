#!/bin/sh
# Exercise the upgrade orchestration with fake git/docker commands.
# The production scripts run in temporary fixture roots, so this never touches
# the real checkout, images, containers, or volumes.
set -eu
cd "$(dirname "$0")/.."

fail() { echo "FAIL  $1" >&2; exit 1; }
assert_called() {
    label="$1"
    needle="$2"
    file="$3"
    grep -qF "$needle" "$file" || fail "$label: missing call: $needle"
}

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture" "${backup_fixture:-}"' EXIT
mkdir -p "$fixture/bin" "$fixture/scripts" "$fixture/upstream/hermes" "$fixture/patches/buzz"
cp scripts/upgrade.sh "$fixture/scripts/upgrade.sh"
cat > "$fixture/scripts/prepare.sh" <<'SH'
#!/bin/sh
printf '%s\n' 'prepare' >> "$FAKE_LOG"
SH
chmod +x "$fixture/scripts/prepare.sh" "$fixture/scripts/upgrade.sh"
cat > "$fixture/patches/buzz/Dockerfile" <<'EOF'
RUN git clone --depth 1 --branch v2026.8.13 \
    https://github.com/NousResearch/hermes-agent.git /opt/hermes-src
EOF
cat > "$fixture/bin/git" <<'SH'
#!/bin/sh
printf 'git %s\n' "$*" >> "$FAKE_LOG"
case " $* " in
    *' checkout '*)
        [ -n "${FAKE_FAIL_CHECKOUT:-}" ] && exit 1
        ;;
    *' ls-remote '*) printf 'target refs/tags/v2026.8.19\n';;
    *' describe '*) printf 'v2026.8.16\n';;
esac
exit 0
SH
cat > "$fixture/bin/docker" <<'SH'
#!/bin/sh
printf 'docker %s\n' "$*" >> "$FAKE_LOG"
exit 0
SH
chmod +x "$fixture/bin/git" "$fixture/bin/docker"

FAKE_LOG="$fixture/calls" PATH="$fixture/bin:$PATH" \
    "$fixture/scripts/upgrade.sh" hermes v2026.8.19 >"$fixture/output" 2>&1 || \
    fail "upgrade script exited non-zero: $(cat "$fixture/output")"

assert_called "build" "docker compose build frontdoor hermes" "$fixture/calls"
assert_called "deploy" "docker compose up -d --force-recreate frontdoor hermes hermes-dashboard" "$fixture/calls"
assert_called "prepare" "prepare" "$fixture/calls"
grep -qF -- '--branch v2026.8.19' "$fixture/patches/buzz/Dockerfile" || \
    fail "frontdoor Hermes pin was not aligned"
sed -E -i 's|(git clone --depth 1 --branch )v[0-9.]+|\1v2026.8.13|' \
    "$fixture/patches/buzz/Dockerfile"
if FAKE_LOG="$fixture/failure-calls" FAKE_FAIL_CHECKOUT=1 PATH="$fixture/bin:$PATH" \
    "$fixture/scripts/upgrade.sh" hermes v2026.8.19 >"$fixture/failure-output" 2>&1; then
    fail "checkout failure unexpectedly succeeded"
fi
grep -qF -- '--branch v2026.8.13' "$fixture/patches/buzz/Dockerfile" || \
    fail "frontdoor Hermes pin changed before checkout succeeded"
mkdir -p "$fixture/upstream/hermes/opc"
touch "$fixture/upstream/hermes/opc/marker"
if FAKE_LOG="$fixture/invalid-calls" PATH="$fixture/bin:$PATH" \
    "$fixture/scripts/upgrade.sh" hermes v2026.8 >"$fixture/invalid-output" 2>&1; then
    fail "invalid Hermes date tag unexpectedly succeeded"
fi
grep -qF ' checkout ' "$fixture/invalid-calls" && \
    fail "invalid Hermes date tag mutated the submodule before validation"
[ -f "$fixture/upstream/hermes/opc/marker" ] || \
    fail "invalid Hermes date tag removed the patched opc tree"
printf '%s\n' 'FROM scratch' > "$fixture/patches/buzz/Dockerfile"
rm -rf "$fixture/upstream/hermes/opc"
mkdir -p "$fixture/upstream/hermes/opc"
touch "$fixture/upstream/hermes/opc/marker"
if FAKE_LOG="$fixture/malformed-calls" PATH="$fixture/bin:$PATH" \
    "$fixture/scripts/upgrade.sh" hermes v2026.8.19 >"$fixture/malformed-output" 2>&1; then
    fail "malformed frontdoor pin unexpectedly succeeded"
fi
grep -qF ' checkout ' "$fixture/malformed-calls" && \
    fail "malformed frontdoor pin mutated the submodule before validation"
[ -f "$fixture/upstream/hermes/opc/marker" ] || \
    fail "malformed frontdoor pin removed the patched opc tree"
printf '%s\n' \
    'RUN git clone --depth 1 --branch v2026.8.13-rc.1 \' \
    '    https://github.com/NousResearch/hermes-agent.git /opt/hermes-src' \
    > "$fixture/patches/buzz/Dockerfile"
rm -rf "$fixture/upstream/hermes/opc"
mkdir -p "$fixture/upstream/hermes/opc"
touch "$fixture/upstream/hermes/opc/marker"
if FAKE_LOG="$fixture/suffix-calls" PATH="$fixture/bin:$PATH" \
    "$fixture/scripts/upgrade.sh" hermes v2026.8.19 >"$fixture/suffix-output" 2>&1; then
    fail "suffixed frontdoor pin unexpectedly succeeded"
fi
grep -qF ' checkout ' "$fixture/suffix-calls" && \
    fail "suffixed frontdoor pin mutated the submodule before validation"
[ -f "$fixture/upstream/hermes/opc/marker" ] || \
    fail "suffixed frontdoor pin removed the patched opc tree"




backup_fixture="$(mktemp -d)"
mkdir -p "$backup_fixture/.claude/skills/upgrade-opc-stack/scripts" "$backup_fixture/bin" "$backup_fixture/scripts"
cp .claude/skills/upgrade-opc-stack/scripts/backup-volumes.sh \
    "$backup_fixture/.claude/skills/upgrade-opc-stack/scripts/backup-volumes.sh"
cp scripts/load-env.sh "$backup_fixture/scripts/load-env.sh"
printf '%s\n' \
    'COMPOSE_PROJECT_NAME=upgrade-test' \
    'PAPERCLIP_EXECUTOR_AGENT_NAME=Fullstack Engineer' > "$backup_fixture/.env"
cat > "$backup_fixture/bin/docker" <<'SH'
#!/bin/sh
printf 'docker %s\n' "$*" >> "$FAKE_LOG"
case "$1" in
    compose)
        [ "${2:-}" = stop ] && exit 0
        ;;
    volume)
        [ "${2:-}" = inspect ] && exit 0
        ;;
    run)
        for arg in "$@"; do
            case "$arg" in
                *:/backup)
                    host="${arg%:/backup}"
                    case "$host" in /*) ;; *) exit 1 ;; esac
                    ;;
                /backup/*.tar.gz) touch "$FAKE_BACKUP_DIR/${arg#/backup/}" ;;
            esac
        done
        exit 0
        ;;
esac
exit 1
SH
chmod +x "$backup_fixture/bin/docker"
FAKE_LOG="$backup_fixture/calls" FAKE_BACKUP_DIR="$backup_fixture/backup/hermes" \
    PATH="$backup_fixture/bin:$PATH" \
    "$backup_fixture/.claude/skills/upgrade-opc-stack/scripts/backup-volumes.sh" \
    hermes backup/hermes v2026.8.16 v2026.8.19 >"$backup_fixture/output" 2>&1 || \
    fail "backup helper exited non-zero: $(cat "$backup_fixture/output")"
assert_called "backup stop" "docker compose stop hermes hermes-dashboard frontdoor" "$backup_fixture/calls"
assert_called "backup gateway volume" "docker volume inspect upgrade-test_hermes-data" "$backup_fixture/calls"
assert_called "backup profiles volume" "docker volume inspect upgrade-test_hermes-profiles" "$backup_fixture/calls"
assert_called "backup frontdoor volume" "docker volume inspect upgrade-test_frontdoor-hermes" "$backup_fixture/calls"
[ "$(wc -l < "$backup_fixture/backup/hermes/manifest.sha256")" -eq 3 ] || \
    fail "backup manifest does not contain three Hermes-related volumes"
grep -qF 'volumes=hermes-data hermes-profiles frontdoor-hermes' \
    "$backup_fixture/backup/hermes/meta.txt" || fail "backup metadata is incomplete"

cp .claude/skills/upgrade-opc-stack/scripts/restore-volumes.sh \
    "$backup_fixture/.claude/skills/upgrade-opc-stack/scripts/restore-volumes.sh"
FAKE_LOG="$backup_fixture/restore-calls" FAKE_BACKUP_DIR="$backup_fixture/backup/hermes" \
    PATH="$backup_fixture/bin:$PATH" \
    "$backup_fixture/.claude/skills/upgrade-opc-stack/scripts/restore-volumes.sh" \
    hermes backup/hermes >"$backup_fixture/restore-output" 2>&1 || \
    fail "restore helper exited non-zero: $(cat "$backup_fixture/restore-output")"
assert_called "restore stop" "docker compose stop hermes hermes-dashboard frontdoor" "$backup_fixture/restore-calls"
assert_called "restore gateway volume" "docker volume inspect upgrade-test_hermes-data" "$backup_fixture/restore-calls"

sed -i 's/^volumes=.*/volumes=hermes-data/' "$backup_fixture/backup/hermes/meta.txt"
if FAKE_LOG="$backup_fixture/legacy-restore-calls" FAKE_BACKUP_DIR="$backup_fixture/backup/hermes" \
    PATH="$backup_fixture/bin:$PATH" \
    "$backup_fixture/.claude/skills/upgrade-opc-stack/scripts/restore-volumes.sh" \
    hermes backup/hermes >"$backup_fixture/legacy-restore-output" 2>&1; then
    fail "legacy Hermes backup was accepted for a complete rollback"
fi

echo "PASS  aligned Hermes upgrade workflow"
echo "PASS  aligned Hermes backup workflow"
echo "PASS  aligned Hermes restore workflow"
