#!/usr/bin/env bash
# Fresh-install rehearsal — the open-box claim, actually executed.
#
# AGENTS.md's deployment assumption is that a clean machine does
#   git clone <repo> && scripts/setup.sh
# and ends up with a fully working stack: no migration script, no manual step.
# Nothing in this repo ever PROVED that. scripts/audit-bootstrap.sh is a
# STATIC audit — it reads patches/ and docker-compose.yml and checks that
# every piece of state names an automatic producer; its own header lists what
# it cannot see (a producer that runs and does nothing, a producer that writes
# the wrong value, an ordering edge nobody wrote a row for). The only thing
# that closes that gap is doing the install for real on empty state, and the
# obvious way to do it — `docker compose down -v` on the live stack — would
# destroy the user's community, board, memories, prototypes and leases.
#
# So this runs the rehearsal BESIDE the live stack instead of on top of it:
# a real `git clone` into a scratch directory, its own compose project, its
# own volumes, its own ports, its own Buzz relay. The live stack keeps
# running and is never a target of any command here.
#
#   scripts/test-fresh-install.sh            # rehearse, then tear down
#   scripts/test-fresh-install.sh --keep     # leave it up for inspection
#   scripts/test-fresh-install.sh --clean    # tear down a leftover rehearsal
#   scripts/test-fresh-install.sh --dry-run  # guards + clone + .env only, no build
#
# Slow and occasional, not CI: the first run builds every image and seeds an
# empty nix store and four empty mise volumes (tens of minutes, ~10 GB of
# docker volumes, ~2 GB of scratch clone). Safe to run twice in a row — the
# first thing it does is dismantle any previous rehearsal.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── knobs ────────────────────────────────────────────────────────────────
TEST_PROJECT="${OPC_REHEARSAL_PROJECT:-opc-rehearsal}"
SCRATCH_ROOT="${OPC_REHEARSAL_ROOT:-${TMPDIR:-/tmp}/opc-fresh-install}"
PORT_OFFSET="${OPC_REHEARSAL_PORT_OFFSET:-1000}"
KEEP=0
CLEAN_ONLY=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --keep)    KEEP=1 ;;
        --clean)   CLEAN_ONLY=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --root)    SCRATCH_ROOT="$2"; shift ;;
        --project) TEST_PROJECT="$2"; shift ;;
        --offset)  PORT_OFFSET="$2"; shift ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

case "$SCRATCH_ROOT" in
    /*/?*) ;;   # must be an absolute path at least two levels deep — `rm -rf`
    *) echo "refusing scratch root '$SCRATCH_ROOT': give an absolute path (it is rm -rf'd)" >&2; exit 2 ;;
esac
if [ "$SCRATCH_ROOT" = "$HOME" ] || [ "$SCRATCH_ROOT" = "$REPO_ROOT" ]; then
    echo "refusing scratch root '$SCRATCH_ROOT': it is rm -rf'd between runs" >&2; exit 2
fi
CLONE="$SCRATCH_ROOT/clone"
# Empty on purpose — see the CLAUDE_CREDENTIALS_FILE override below.
CLAUDE_CRED_STUB="$SCRATCH_ROOT/claude-credentials-absent.json"

die() { printf '\nABORT  %s\n' "$*" >&2; exit 1; }
step() { printf '\n── %s ──\n' "$*"; }

# The harness must never inherit the operator's shell view of the stack.
# `export COMPOSE_PROJECT_NAME=opc` in an interactive shell outranks the
# clone's .env in compose's precedence order, which would silently aim the
# whole rehearsal — including `down -v` — at the LIVE project. Nothing below
# reads these; drop them so nothing can.
unset COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_ENV_FILES COMPOSE_PROFILES \
      IMAGE_PREFIX BUZZ_RELAY_URL PAPERCLIP_PUBLIC_URL CLAUDE_CREDENTIALS_FILE \
      BUZZ_PORT HERMES_API_PORT HERMES_DASHBOARD_PORT PAPERCLIP_PORT \
      DEVENV_PG_PORT DEVENV_VALKEY_PORT TENCENTDB_CORE_PORT \
      TENCENTDB_PANEL_PORT TENCENTDB_KNOWLEDGE_PORT TENCENTDB_PROXY_PORT \
      DEVENV_HTTP_PORT_BASE DEVENV_HTTP_PORT_COUNT DEVENV_HTTP_PORT_RANGE_END \
      DEVENV_HTTP_BIND DEVENV_SECRET_SALT 2>/dev/null || true

# env_value <file> <key> — read ONE value with the same parser the stack uses.
#
# In a subshell so the exports die with it: this script reads the LIVE .env,
# and leaking those exports into its own environment is exactly the accident
# the `unset` above guards against.
env_value() {
    ( . "$REPO_ROOT/scripts/load-env.sh"; opc_load_env "$1"; eval "printf '%s' \"\${$2-}\"" )
}

# ── what the live stack is, so we can be certain we are not it ───────────
[ -f "$REPO_ROOT/.env" ] || die "no $REPO_ROOT/.env — the rehearsal copies the LLM key and derives its host from the live config"

LIVE_PROJECT="$(env_value "$REPO_ROOT/.env" COMPOSE_PROJECT_NAME)"
[ -n "$LIVE_PROJECT" ] || LIVE_PROJECT=opc
LIVE_RELAY="$(env_value "$REPO_ROOT/.env" BUZZ_RELAY_URL)"
[ -n "$LIVE_RELAY" ] || die "live .env has no BUZZ_RELAY_URL — cannot prove the rehearsal relay differs from it"

[ "$TEST_PROJECT" != "$LIVE_PROJECT" ] || \
    die "rehearsal project name '$TEST_PROJECT' equals the live project — every volume would be shared and the teardown would delete the live stack. Pass --project."

# Reachable host, taken from the live relay URL: ws://<host>:<port> → <host>.
# The rehearsal has to use a routable address for the same reason the live
# stack does (.env.example: the hermes container does not share the relay's
# netns), and the live value is the one address already known to work here.
HOST="${LIVE_RELAY#*://}"; HOST="${HOST%%/*}"; HOST="${HOST%%:*}"
[ -n "$HOST" ] || die "could not parse a host out of BUZZ_RELAY_URL='$LIVE_RELAY'"

# ── destructive-operation guard ──────────────────────────────────────────
# Every `down -v` / `rm` below calls this first. The check is deliberately
# three-sided: non-empty (an unset variable would make `docker compose -p ''`
# fall back to the directory name), equal to the rehearsal project, and not
# equal to the live one.
assert_rehearsal_project() {
    local p="${1-}"
    [ -n "$p" ] || die "internal: destructive command with an empty compose project"
    [ "$p" = "$TEST_PROJECT" ] || die "internal: destructive command aimed at '$p', not the rehearsal project '$TEST_PROJECT'"
    [ "$p" != "$LIVE_PROJECT" ] || die "internal: rehearsal project equals the live project '$LIVE_PROJECT'"
}

teardown() {
    assert_rehearsal_project "$TEST_PROJECT"
    step "teardown ($TEST_PROJECT)"
    # Preferred path: the clone's own compose file, with the project passed
    # explicitly rather than inferred from the working directory.
    if [ -f "$CLONE/docker-compose.yml" ] && [ -f "$CLONE/.env" ]; then
        assert_rehearsal_project "$TEST_PROJECT"
        docker compose -p "$TEST_PROJECT" \
            --project-directory "$CLONE" \
            --env-file "$CLONE/.env" \
            -f "$CLONE/docker-compose.yml" \
            down -v --remove-orphans --timeout 30 || true
    fi
    # Fallback sweep for the case the clone is already gone (a previous run
    # interrupted between teardown and rm -rf, or --root pointed elsewhere).
    # Label-filtered, so it can only ever see objects compose stamped with
    # THIS project name.
    assert_rehearsal_project "$TEST_PROJECT"
    local ids
    ids="$(docker ps -aq --filter "label=com.docker.compose.project=$TEST_PROJECT" 2>/dev/null || true)"
    [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1 || true
    ids="$(docker volume ls -q --filter "label=com.docker.compose.project=$TEST_PROJECT" 2>/dev/null || true)"
    [ -n "$ids" ] && docker volume rm -f $ids >/dev/null 2>&1 || true
    ids="$(docker network ls -q --filter "label=com.docker.compose.project=$TEST_PROJECT" 2>/dev/null || true)"
    [ -n "$ids" ] && docker network rm $ids >/dev/null 2>&1 || true
    return 0
}

if [ "$CLEAN_ONLY" = 1 ]; then
    teardown
    rm -rf "$SCRATCH_ROOT"
    # Images are the one thing a normal teardown KEEPS — they share almost all
    # their layers with the live stack's (measured: eight rehearsal images add
    # ~1.5 GB on top of a 47 GB store) and keeping them makes the next
    # rehearsal's build phase near-instant. `--clean` is the explicit "get rid
    # of it" command, so here they go.
    assert_rehearsal_project "$TEST_PROJECT"
    imgs="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "^$TEST_PROJECT/" || true)"
    [ -n "$imgs" ] && docker rmi $imgs >/dev/null 2>&1 || true
    echo "rehearsal '$TEST_PROJECT' removed (scratch: $SCRATCH_ROOT, images included)"
    exit 0
fi

# ── the three gates must follow the CLONE's .env, not this repo's ────────
# The whole design rests on it: they are invoked inside the clone and are
# expected to pick up its project name and its ports. Both halves are load
# bearing — the `cd` to their own repo root, and reading ./.env from there —
# so assert them instead of assuming. A gate that hardcoded a port, or that
# read $REPO_ROOT/.env, would silently probe the LIVE stack and report the
# rehearsal green.
GATES="scripts/audit-bootstrap.sh scripts/test-connectivity.sh scripts/test-scientist.sh"
step "preflight: gates are relocatable"
for g in $GATES; do
    [ -x "$REPO_ROOT/$g" ] || die "$g missing or not executable"
    grep -q 'cd "$(dirname "$0")/\.\."' "$REPO_ROOT/$g" || \
        die "$g does not cd to its own repo root — it would not follow the clone"
    # audit-bootstrap.sh is a pure file audit and reads no .env; the other two
    # drive a running stack and must resolve ports/project from the clone's.
    case "$g" in
        scripts/audit-bootstrap.sh) ;;
        *) grep -q 'opc_load_env \./\.env' "$REPO_ROOT/$g" || \
               die "$g does not load ./.env — it would not follow the clone's ports" ;;
    esac
    echo "ok  $g"
done

# ── ports ────────────────────────────────────────────────────────────────
# Defaults come from .env.example (the clean-machine values this rehearsal is
# about), live values from the live .env, so neither set is hardcoded here.
PORT_KEYS="BUZZ_PORT:3000
HERMES_API_PORT:8642
HERMES_DASHBOARD_PORT:9119
PAPERCLIP_PORT:3100
DEVENV_PG_PORT:5433
DEVENV_VALKEY_PORT:6380
TENCENTDB_CORE_PORT:8420
TENCENTDB_PANEL_PORT:8125
TENCENTDB_KNOWLEDGE_PORT:8424
TENCENTDB_PROXY_PORT:8096"

base_port() { # <key> <fallback>
    local v; v="$(env_value "$REPO_ROOT/.env.example" "$1")"
    [ -n "$v" ] || v="$2"
    printf '%s' "$v"
}
live_port() { # <key> <fallback>
    local v; v="$(env_value "$REPO_ROOT/.env" "$1")"
    [ -n "$v" ] || v="$(base_port "$1" "$2")"
    printf '%s' "$v"
}

TEST_PORTS=""
LIVE_PORTS=""
declare -A TEST_PORT_OF=()
while IFS=: read -r key def; do
    [ -n "$key" ] || continue
    tp=$(( $(base_port "$key" "$def") + PORT_OFFSET ))
    TEST_PORT_OF["$key"]=$tp
    TEST_PORTS="$TEST_PORTS $tp"
    LIVE_PORTS="$LIVE_PORTS $(live_port "$key" "$def")"
done <<EOF
$PORT_KEYS
EOF

# The preview range is not in .env.example's active section — compose defaults
# it (21000/16/21015). BASE and RANGE_END are two sources for one fact because
# compose cannot do arithmetic, so both are written explicitly and derived
# from one expression here.
PREVIEW_COUNT="${OPC_REHEARSAL_PREVIEW_COUNT:-16}"
PREVIEW_BASE=$(( 21000 + PORT_OFFSET ))
PREVIEW_END=$(( PREVIEW_BASE + PREVIEW_COUNT - 1 ))
LIVE_PREVIEW_BASE="$(env_value "$REPO_ROOT/.env" DEVENV_HTTP_PORT_BASE)"; [ -n "$LIVE_PREVIEW_BASE" ] || LIVE_PREVIEW_BASE=21000
LIVE_PREVIEW_END="$(env_value "$REPO_ROOT/.env" DEVENV_HTTP_PORT_RANGE_END)"; [ -n "$LIVE_PREVIEW_END" ] || LIVE_PREVIEW_END=21015

step "preflight: port allocation (offset +$PORT_OFFSET)"
# Above 32768 a leased-but-not-listening preview port can be stolen by any
# process's bind(0) (AGENTS.md, prototype/preview pitfall 3).
[ "$PREVIEW_END" -lt 32768 ] || die "preview range $PREVIEW_BASE-$PREVIEW_END reaches into the kernel ephemeral range (>=32768)"

# Uniqueness within the new set, and against everything the live stack owns.
seen=""
for p in $TEST_PORTS; do
    case " $seen " in *" $p "*) die "rehearsal ports collide with each other at $p" ;; esac
    seen="$seen $p"
    for lp in $LIVE_PORTS; do
        [ "$p" != "$lp" ] || die "rehearsal port $p is already a LIVE stack port — pick another --offset"
    done
    if [ "$p" -ge "$LIVE_PREVIEW_BASE" ] && [ "$p" -le "$LIVE_PREVIEW_END" ]; then
        die "rehearsal port $p falls inside the live preview range $LIVE_PREVIEW_BASE-$LIVE_PREVIEW_END"
    fi
    if [ "$p" -ge "$PREVIEW_BASE" ] && [ "$p" -le "$PREVIEW_END" ]; then
        die "rehearsal port $p falls inside the rehearsal preview range $PREVIEW_BASE-$PREVIEW_END"
    fi
done
if [ "$PREVIEW_BASE" -le "$LIVE_PREVIEW_END" ] && [ "$PREVIEW_END" -ge "$LIVE_PREVIEW_BASE" ]; then
    die "rehearsal preview range $PREVIEW_BASE-$PREVIEW_END overlaps the live one $LIVE_PREVIEW_BASE-$LIVE_PREVIEW_END"
fi

# Anything else on the host counts too — the collision that matters is with
# whatever is listening now, not only with our own two configs. Checked after
# the teardown below, so a previous rehearsal's own sockets do not trip it.
check_free_ports() {
    command -v ss >/dev/null 2>&1 || { echo "note: ss(8) not found — skipping the live-socket collision check"; return 0; }
    local listening; listening=" $(ss -ltnH 2>/dev/null | awk '{n=split($4,a,":"); print a[n]}' | sort -nu | tr '\n' ' ')"
    local p
    for p in $TEST_PORTS $(seq "$PREVIEW_BASE" "$PREVIEW_END"); do
        case "$listening" in *" $p "*) die "port $p is already bound on this host" ;; esac
    done
}

echo "rehearsal project : $TEST_PROJECT   (live: $LIVE_PROJECT)"
echo "rehearsal ports   :$TEST_PORTS  preview $PREVIEW_BASE-$PREVIEW_END"
echo "scratch clone     : $CLONE"

# ── previous rehearsal first, so a re-run is a clean run ─────────────────
teardown
rm -rf "$SCRATCH_ROOT"
check_free_ports

# ── clone ────────────────────────────────────────────────────────────────
# A CLONE, not a copy of the working tree. The claim under test is about what
# somebody else gets from `git clone`, and only a clone exposes the state the
# working tree hides: gitignored files, untracked helpers, anything never
# committed. A `cp -a` would rehearse this machine, not the repository.
step "clone $REPO_ROOT @ HEAD"
mkdir -p "$SCRATCH_ROOT"
HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
if [ -n "$(git -C "$REPO_ROOT" status --porcelain --ignore-submodules 2>/dev/null)" ]; then
    echo "⚠  working tree has uncommitted changes — they are NOT in the clone."
    echo "   The rehearsal tests commit $HEAD_SHA, which is the point, but if you"
    echo "   meant to test an edit, commit it first."
fi
git clone --quiet "$REPO_ROOT" "$CLONE"
git -C "$CLONE" checkout --quiet --detach "$HEAD_SHA"
echo "cloned at $HEAD_SHA"

# Submodules are re-pointed at the local upstream checkouts before setup.sh
# initialises them. Fetching buzz + hermes + paperclip + tencentdb from
# GitHub costs several GB per rehearsal and turns a test that should be run
# occasionally into one nobody runs; and it is not what is under test — the
# subject is OUR scripts, patches and compose reaching a working state from
# empty, not GitHub's availability. The pinned SHAs are still checked out
# exactly as .gitmodules records them.
#
# THE TRADE: this cannot catch a submodule tag that has disappeared upstream
# (deleted repo, retagged release, force-pushed history). A rehearsal is green
# and a genuine clean machine still fails at `git submodule update`. Nothing
# here covers that; re-clone from GitHub occasionally if you want it.
#
# Written into the clone's .git/config, never into .gitmodules: `submodule
# update --init` prefers the configured URL and leaves the tracked file alone,
# so the clone stays byte-identical to HEAD.
step "point submodules at local upstream checkouts"
git -C "$CLONE" submodule init >/dev/null
git -C "$CLONE" config -f "$CLONE/.gitmodules" --get-regexp '^submodule\..*\.path$' \
| while read -r cfgkey subpath; do
    name="${cfgkey#submodule.}"; name="${name%.path}"
    [ -d "$REPO_ROOT/$subpath/.git" ] || [ -f "$REPO_ROOT/$subpath/.git" ] || \
        die "$REPO_ROOT/$subpath is not an initialised submodule — run scripts/setup.sh in the live repo first"
    git -C "$CLONE" config "submodule.$name.url" "$REPO_ROOT/$subpath"
    echo "$name → $REPO_ROOT/$subpath"
done
# git >=2.38 refuses the `file` transport for submodules (CVE-2022-39253) and
# the refusal happens in the child clone, where the superproject's local
# config is not in scope — a repo-level `git config` is silently ignored. The
# GIT_CONFIG_* environment form is the only lever that reaches setup.sh's own
# `git submodule update --init`, so it is exported for that call rather than
# baked into the clone.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always

# ── .env ─────────────────────────────────────────────────────────────────
step "generate the rehearsal .env"
cp "$CLONE/.env.example" "$CLONE/.env"

set_env() { # <key> <value> — overwrite the assignment in the clone's .env
    python3 - "$CLONE/.env" "$1" "$2" <<'PY'
import re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
line = "%s=%s" % (key, val)
# A LIVE assignment first, a commented one only if there is no live one, and
# append as the last resort. The order matters: .env.example documents several
# keys with a commented EXAMPLE line sitting just above the real assignment
# (PAPERCLIP_ALLOWED_HOSTNAMES), so "replace whichever comes first" rewrote the
# comment and left the real value below it to win — an override that looked
# applied in the diff and did nothing in the stack.
live = r'(?m)^[ \t]*%s=.*$' % re.escape(key)
cmt  = r'(?m)^#[ \t]*%s=.*$' % re.escape(key)
if re.search(live, src):
    src = re.sub(live, lambda m: line, src, count=1)
elif re.search(cmt, src):
    src = re.sub(cmt, lambda m: line, src, count=1)
else:
    src = src.rstrip("\n") + "\n" + line + "\n"
open(path, "w").write(src)
PY
}

set_env COMPOSE_PROJECT_NAME "$TEST_PROJECT"
# A separate image prefix is nearly free — the BuildKit layer cache is shared,
# so only the tags are new. The expensive half is the per-project VOLUMES (an
# empty nix store to seed, four empty mise volumes to populate), and that is
# precisely the path a clean machine takes and the one worth rehearsing.
set_env IMAGE_PREFIX "$TEST_PROJECT"

for key in $(printf '%s\n' "$PORT_KEYS" | cut -d: -f1); do
    set_env "$key" "${TEST_PORT_OF[$key]}"
done
set_env DEVENV_HTTP_PORT_BASE "$PREVIEW_BASE"
set_env DEVENV_HTTP_PORT_COUNT "$PREVIEW_COUNT"
set_env DEVENV_HTTP_PORT_RANGE_END "$PREVIEW_END"
set_env DEVENV_HTTP_BIND "$HOST"

# INVARIANT 1 — one canonical Buzz host = one community, enforced by NIP-42/98
# signature verification against the connecting host string. If the rehearsal
# relay URL ever equalled the live one, this stack would not be a separate
# community: its front-door and expert agents would authenticate into the
# USER'S REAL community and publish their identities and posts there, and
# `down -v` at the end would leave those members behind in a relay it never
# owned. The relay port is the only thing distinguishing them, so refuse
# outright rather than warn.
TEST_RELAY="ws://$HOST:${TEST_PORT_OF[BUZZ_PORT]}"
[ "$TEST_RELAY" != "$LIVE_RELAY" ] || \
    die "rehearsal BUZZ_RELAY_URL ($TEST_RELAY) equals the live one. One canonical host = one community (invariant 1): the rehearsal agents would join the real community and sign into it. Change --offset so the relay ports differ."
set_env BUZZ_RELAY_URL "$TEST_RELAY"

set_env PAPERCLIP_PUBLIC_URL "http://$HOST:${TEST_PORT_OF[PAPERCLIP_PORT]}"
set_env PAPERCLIP_ALLOWED_HOSTNAMES "paperclip,$HOST"
set_env TENCENTDB_KNOWLEDGE_PUBLIC_URL "http://$HOST:${TEST_PORT_OF[TENCENTDB_KNOWLEDGE_PORT]}/v3"

# Distinct from the live salt (per-tenant devenv credentials are DERIVED from
# it, not stored) but stable across rehearsals, so a --keep stack's handed-out
# .env files survive a re-provision.
set_env DEVENV_SECRET_SALT "$(printf 'opc-fresh-install-rehearsal:%s' "$TEST_PROJECT" | sha256sum | cut -c1-64)"

# An EMPTY file, not the host's credential. AGENTS.md: the Claude OAuth
# refresh token is single-use, so whichever container refreshes it invalidates
# every other copy including the host's own login — two stacks holding it is
# two chances to log the human out. claude_local is wired to nothing today
# (the prototyper's HOME never reaches its child process), so an absent login
# costs no coverage: scripts/hooks/claude-cred.sh reads empty as "not logged
# in", WARNs and exits 0, which is itself a clean-machine path worth walking.
: > "$CLAUDE_CRED_STUB"
set_env CLAUDE_CREDENTIALS_FILE "$CLAUDE_CRED_STUB"

# The LLM key, so the rehearsal stack is genuinely functional rather than a
# shape with no provider. Written by value into the clone's .env; never echoed.
LIVE_OPENAI_KEY="$(env_value "$REPO_ROOT/.env" OPENAI_API_KEY)"
[ -n "$LIVE_OPENAI_KEY" ] || die "live .env has no OPENAI_API_KEY — the rehearsal stack would come up without a provider"
set_env OPENAI_API_KEY "$LIVE_OPENAI_KEY"
for k in OPENAI_BASE_URL OPENAI_MODEL BUZZ_AGENT_MODEL; do
    v="$(env_value "$REPO_ROOT/.env" "$k")"
    [ -n "$v" ] && set_env "$k" "$v"
done
unset LIVE_OPENAI_KEY

grep -vE '^(OPENAI_API_KEY|.*_PASSWORD|.*_SECRET|.*_KEY)=' "$CLONE/.env" \
    | grep -E '^(COMPOSE_PROJECT_NAME|IMAGE_PREFIX|BUZZ_RELAY_URL|PAPERCLIP_PUBLIC_URL|PAPERCLIP_ALLOWED_HOSTNAMES|DEVENV_HTTP[A-Z_]*|CLAUDE_CREDENTIALS_FILE|[A-Z_]*_PORT)=' \
    | sed 's/^/  /' || true

if [ "$DRY_RUN" = 1 ]; then
    step "--dry-run: stopping before setup.sh"
    echo "the clone and its .env are at $CLONE"
    [ "$KEEP" = 1 ] || rm -rf "$SCRATCH_ROOT"
    exit 0
fi

# ── the actual open-box run ──────────────────────────────────────────────
step "scripts/setup.sh (clean state — this is the slow part)"
SETUP_RC=0
( cd "$CLONE" && ./scripts/setup.sh ) || SETUP_RC=$?
[ "$SETUP_RC" = 0 ] || echo "⚠  setup.sh exited $SETUP_RC — running the gates anyway, they localise the damage"

# ── gates, from the clone ────────────────────────────────────────────────
GATE_RESULT=""
OVERALL=0
for g in $GATES; do
    step "$g (from the clone)"
    rc=0
    ( cd "$CLONE" && "./$g" ) || rc=$?
    [ "$rc" = 0 ] || OVERALL=1
    GATE_RESULT="$GATE_RESULT$(printf '  %-32s %s\n' "$g" "$([ "$rc" = 0 ] && echo PASS || echo "FAIL (exit $rc)")")
"
done

step "rehearsal result"
[ "$SETUP_RC" = 0 ] && echo "  setup.sh                         PASS" || { echo "  setup.sh                         FAIL (exit $SETUP_RC)"; OVERALL=1; }
printf '%s' "$GATE_RESULT"

# ── teardown ─────────────────────────────────────────────────────────────
# Kept on failure by default: a torn-down stack cannot be diagnosed, and the
# next run dismantles it anyway.
if [ "$KEEP" = 1 ]; then
    echo
    echo "kept for inspection (--keep): $CLONE"
    echo "  board     http://$HOST:${TEST_PORT_OF[PAPERCLIP_PORT]}"
    echo "  dashboard http://$HOST:${TEST_PORT_OF[HERMES_DASHBOARD_PORT]}"
    echo "  remove it: scripts/test-fresh-install.sh --clean"
elif [ "$OVERALL" != 0 ]; then
    echo
    echo "⚠  rehearsal FAILED — the stack is left up so you can look at it:"
    echo "     cd $CLONE && docker compose logs <service>"
    echo "   remove it when done: scripts/test-fresh-install.sh --clean"
else
    teardown
    rm -rf "$SCRATCH_ROOT"
    echo "torn down; scratch removed. Rehearsal IMAGES are kept (they share"
    echo "almost every layer with the live stack's, and they make the next run"
    echo "skip the build phase). 'scripts/test-fresh-install.sh --clean' drops them."
fi

exit "$OVERALL"
