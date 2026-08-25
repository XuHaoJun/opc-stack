#!/usr/bin/env bash
# Report whether the pinned upstream/ submodules have newer stable tags.
#   scripts/outdated.sh [buzz|hermes|paperclip|tencentdb ...]   # default: all
#
# `npm outdated` for this stack's four pins: read-only, prints one row per
# component, and suggests the scripts/upgrade.sh line that closes each gap.
# Exit status follows npm's convention:
#   0  everything is on the newest stable tag in its family
#   1  at least one component has a newer stable tag
#   2  the report is incomplete (unreachable origin, untagged pin, pin drift)
# 2 beats 1: a partial report must never read as a clean one.
#
# WHAT COUNTS AS "STABLE" — inferred from the pin, not configured. The pinned
# tag splits into a literal prefix and a numeric version (desktop-v + 0.5.14,
# v + 2026.817.0); candidates are remote tags with the SAME prefix and at least
# as many all-numeric dot components. That single rule does three jobs:
#   * anchoring on numeric components drops -rc.N / -canary.N / -beta.N /
#     -nightly.N without maintaining a suffix blocklist (paperclip has 1118
#     canary tags against 21 stable ones);
#   * the literal prefix keeps buzz's 12 tag families apart, so a desktop pin
#     is never "upgraded" to a mobile- release;
#   * allowing MORE components than the pin keeps a hotfix shape like hermes'
#     v2026.8.16.2 eligible instead of invisible.
# Repin a submodule to a different family and this report follows it; there is
# no table here to keep in sync.
#
# Two deliberate refusals:
#   * `git describe` is NOT used to read the current pin. It reports buzz as
#     mobile-v0.11.0-rc.2-22-g391495e7d and paperclip as
#     @paperclipai/adapter-claude-local@0.3.1-2649-g213dabab4 — both the wrong
#     family, which is the exact mistake this tool exists to prevent.
#     `git tag --points-at HEAD` is the only honest source.
#   * ordering is computed here (component-wise, numeric), not with sort/LC
#     collation: desktop-v0.5.9 is lexically greater than desktop-v0.5.18.
#
# The `tagged` column is the committer date of the commit the newest tag points
# at — NOT the date the version number claims. Paperclip's v2026.824.0 tags a
# commit from 2026-08-17, 80 minutes after v2026.817.0's: those numbers are
# planned release dates. The commit date is the only thing actually measured.
#
# Network use is `git ls-remote` only — no checkout, ref, or HEAD is touched.
# The one exception is the release date: if the newest tag's commit is missing
# from the local object store (a fresh clone), a bounded
# `fetch --depth 1 --no-tags refs/tags/<tag>` pulls that one commit's objects;
# if even that fails the date degrades to `?` and the rest of the row stands.
#
# Scope is upstream/ only. The stack's other pins (nix, nixpkgs, RustFS,
# rabbitmq, mc, omp) live in Dockerfiles with no tag namespace to sort.
set -uo pipefail
cd "$(dirname "$0")/.."

ORDER=(buzz hermes paperclip tencentdb)
# Component → submodule directory. tencentdb's submodule is NOT named after the
# component, the same mismatch prepare.sh and upgrade.sh already carry.
declare -A SUBMODULE=(
  [buzz]=buzz
  [hermes]=hermes
  [paperclip]=paperclip
  [tencentdb]=tencentdb-agent-memory
)

usage() {
  echo "usage: scripts/outdated.sh [${ORDER[*]}]" >&2
  echo "  no arguments: report every component" >&2
}

SELECTED=()
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 2 ;;
    *)
      if [ -z "${SUBMODULE[$arg]:-}" ]; then
        echo "unknown component '$arg'" >&2
        usage
        exit 2
      fi
      SELECTED+=("$arg")
      ;;
  esac
done
[ ${#SELECTED[@]} -gt 0 ] || SELECTED=("${ORDER[@]}")

WORST=0
bump() { [ "$1" -gt "$WORST" ] && WORST="$1"; return 0; }

WARNINGS=()
warn() { WARNINGS+=("$1"); }

# Split a tag into "<prefix>\t<version>", dropping one trailing pre-release
# segment first so a pre-release pin still names the family it belongs to.
# The prefix is everything up to the trailing run of [0-9.] — anchoring on the
# last non-numeric character is what keeps `desktop-v` and `@scope/pkg@` whole.
split_tag() {
  local tag="$1" core ver prefix
  core="$tag"
  if [[ "$core" =~ ^(.+[0-9])-[A-Za-z][A-Za-z0-9]*(\.[0-9]+)?$ ]]; then
    core="${BASH_REMATCH[1]}"
  fi
  ver="${core##*[!0-9.]}"
  prefix="${core%"$ver"}"
  [[ "$ver" =~ ^[0-9]+(\.[0-9]+)+$ ]] || return 1
  printf '%s\t%s\n' "$prefix" "$ver"
}

# Component-wise numeric version comparison, shared by every caller below so
# there is exactly one ordering rule in this script. Missing components read as
# zero, which is what makes 2026.8.16.2 > 2026.8.16 and 0.5.18 > 0.5.9.
VCMP_AWK='
function vcmp(a, b,   x, y, i, m, na, nb, xa, yb) {
  na = split(a, x, "."); nb = split(b, y, ".")
  m = (na > nb) ? na : nb
  for (i = 1; i <= m; i++) {
    xa = (i <= na) ? x[i] + 0 : 0
    yb = (i <= nb) ? y[i] + 0 : 0
    if (xa > yb) return 1
    if (xa < yb) return -1
  }
  return 0
}'

# True when version $1 is newer than version $2.
ver_gt() {
  awk -v a="$1" -v b="$2" "$VCMP_AWK"'
    BEGIN { exit (vcmp(a, b) > 0) ? 0 : 1 }
  '
}

# Pick the newest stable tag in a family and count how many outrank the pin.
# Reads tag names on stdin, prints "<tag>\t<version>\t<behind>", exit 1 if the
# family is empty.
family_latest() {
  awk -v p="$1" -v n="$2" -v pin="$3" "$VCMP_AWK"'
    BEGIN { plen = length(p); best = ""; bestv = ""; behind = 0 }
    {
      if (substr($0, 1, plen) != p) next
      rest = substr($0, plen + 1)
      if (rest !~ /^[0-9]+(\.[0-9]+)*$/) next
      if (split(rest, parts, ".") < n) next
      if (best == "" || vcmp(rest, bestv) > 0) { best = $0; bestv = rest }
      if (vcmp(rest, pin) > 0) behind++
    }
    END {
      if (best == "") exit 1
      printf "%s\t%s\t%d\n", best, bestv, behind
    }
  '
}

# Hermes is pinned twice: the submodule, and the checkout the frontdoor image
# bakes. upgrade.sh aligns them; nothing else notices when they drift.
# Same extract-and-assert-exactly-one shape as upgrade.sh, so both fail loudly
# if that Dockerfile line ever changes form.
FRONTDOOR_PIN_FILE=patches/buzz/Dockerfile
frontdoor_pin() {
  local pin count
  [ -f "$FRONTDOOR_PIN_FILE" ] || return 1
  pin="$(sed -n -E 's/.*git clone --depth 1 --branch (v[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2})[[:space:]].*/\1/p' "$FRONTDOOR_PIN_FILE")"
  count="$(printf '%s\n' "$pin" | sed '/^$/d' | wc -l)"
  [ "$count" = 1 ] || return 1
  printf '%s\n' "$pin"
}

ROWS=()
UPGRADES=()
OUTDATED=0

for proj in "${SELECTED[@]}"; do
  dir="upstream/${SUBMODULE[$proj]}"
  if [ ! -d "$dir" ]; then
    ROWS+=("$proj"$'\t'"?"$'\t'"?"$'\t'"?"$'\t'"?")
    warn "$proj: $dir is missing — run 'git submodule update --init'"
    bump 2
    continue
  fi

  mapfile -t head_tags < <(git -C "$dir" tag --points-at HEAD 2>/dev/null)
  pin_tag=""
  pin_prefix=""
  pin_ver=""
  for tag in "${head_tags[@]}"; do
    [ -n "$tag" ] || continue
    if split="$(split_tag "$tag")"; then
      prefix="${split%%$'\t'*}"
      ver="${split##*$'\t'}"
      if [ -z "$pin_tag" ] || ver_gt "$ver" "$pin_ver"; then
        pin_tag="$tag"; pin_prefix="$prefix"; pin_ver="$ver"
      fi
    fi
  done
  if [ -z "$pin_tag" ]; then
    ROWS+=("$proj"$'\t'"?"$'\t'"?"$'\t'"?"$'\t'"?")
    warn "$proj: HEAD is not on a tag this report can read (${head_tags[*]:-no tags at HEAD}) — repin the submodule to a release tag"
    bump 2
    continue
  fi
  if [ "${#head_tags[@]}" -gt 1 ]; then
    warn "$proj: more than one tag at HEAD (${head_tags[*]}); reporting against $pin_tag"
  fi
  ncomp="$(awk -F. '{print NF}' <<<"$pin_ver")"

  if ! remote="$(git -C "$dir" ls-remote --tags origin 2>&1)"; then
    ROWS+=("$proj"$'\t'"$pin_tag"$'\t'"?"$'\t'"?"$'\t'"?")
    warn "$proj: could not list tags on origin ($(printf '%s' "$remote" | tail -1))"
    bump 2
    continue
  fi
  tags="$(printf '%s\n' "$remote" | sed -n -E 's#^[0-9a-f]+[[:space:]]+refs/tags/(.*)$#\1#p' | grep -v '\^{}$' || true)"
  if ! found="$(printf '%s\n' "$tags" | family_latest "$pin_prefix" "$ncomp" "$pin_ver")"; then
    ROWS+=("$proj"$'\t'"$pin_tag"$'\t'"?"$'\t'"?"$'\t'"?")
    warn "$proj: no stable tags in family '${pin_prefix}*' on origin — the pin ($pin_tag) may be a pre-release"
    bump 2
    continue
  fi
  latest="$(printf '%s' "$found" | cut -f1)"
  behind="$(printf '%s' "$found" | cut -f3)"

  # Release date of the newest tag: prefer the dereferenced commit of an
  # annotated tag, fall back to the tag object's own line.
  sha="$(printf '%s\n' "$remote" | awk -v t="refs/tags/$latest^{}" '$2 == t { print $1; exit }')"
  [ -n "$sha" ] || sha="$(printf '%s\n' "$remote" | awk -v t="refs/tags/$latest" '$2 == t { print $1; exit }')"
  tagged="$(git -C "$dir" log -1 --format=%cs "$sha" 2>/dev/null || true)"
  if [ -z "$tagged" ]; then
    if git -C "$dir" fetch --depth 1 --no-tags --quiet origin "refs/tags/$latest" 2>/dev/null; then
      tagged="$(git -C "$dir" log -1 --format=%cs FETCH_HEAD 2>/dev/null || true)"
    fi
  fi
  [ -n "$tagged" ] || tagged="?"

  if [ "$behind" -gt 0 ]; then
    ROWS+=("$proj"$'\t'"$pin_tag"$'\t'"$latest"$'\t'"$behind"$'\t'"$tagged")
    UPGRADES+=("$proj"$'\t'"$latest")
    OUTDATED=$((OUTDATED + 1))
    bump 1
  else
    ROWS+=("$proj"$'\t'"$pin_tag"$'\t'"$latest"$'\t'"-"$'\t'"$tagged")
  fi

  if [ "$proj" = hermes ]; then
    if ! fd_pin="$(frontdoor_pin)"; then
      warn "hermes: could not read exactly one frontdoor pin from $FRONTDOOR_PIN_FILE — upgrade.sh will refuse too"
      bump 2
    elif [ "$fd_pin" != "$pin_tag" ]; then
      warn "hermes: $FRONTDOOR_PIN_FILE pins $fd_pin but the submodule pins $pin_tag — the frontdoor image bakes its own checkout, so these must match"
      bump 2
    fi
  fi
done

# ── table ────────────────────────────────────────────────────────────────────
HEADER=("component" "current" "latest" "behind" "tagged")
widths=(0 0 0 0 0)
for i in 0 1 2 3; do widths[i]="${#HEADER[i]}"; done
for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r -a cells <<<"$row"
  for i in 0 1 2 3; do
    [ "${#cells[i]}" -gt "${widths[i]}" ] && widths[i]="${#cells[i]}"
  done
done
printf '%-*s  %-*s  %-*s  %-*s  %s\n' \
  "${widths[0]}" "${HEADER[0]}" "${widths[1]}" "${HEADER[1]}" \
  "${widths[2]}" "${HEADER[2]}" "${widths[3]}" "${HEADER[3]}" "${HEADER[4]}"
for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r -a cells <<<"$row"
  printf '%-*s  %-*s  %-*s  %-*s  %s\n' \
    "${widths[0]}" "${cells[0]}" "${widths[1]}" "${cells[1]}" \
    "${widths[2]}" "${cells[2]}" "${widths[3]}" "${cells[3]}" "${cells[4]}"
done

echo
total="${#SELECTED[@]}"
if [ "$OUTDATED" -eq 0 ]; then
  if [ "$total" -eq 1 ]; then
    echo "${SELECTED[0]} is on the newest stable tag in its family."
  else
    echo "all $total components are on the newest stable tag in their family."
  fi
else
  if [ "$OUTDATED" -eq 1 ]; then
    echo "1 of $total components has a newer stable tag:"
  else
    echo "$OUTDATED of $total components have newer stable tags:"
  fi
  cmd_width=0
  for up in "${UPGRADES[@]}"; do
    name="${up%%$'\t'*}"
    [ "${#name}" -gt "$cmd_width" ] && cmd_width="${#name}"
  done
  for up in "${UPGRADES[@]}"; do
    name="${up%%$'\t'*}"
    tag="${up##*$'\t'}"
    printf '  scripts/upgrade.sh %-*s %s\n' "$cmd_width" "$name" "$tag"
  done
fi

if [ "${#WARNINGS[@]}" -gt 0 ]; then
  echo >&2
  for w in "${WARNINGS[@]}"; do echo "warning: $w" >&2; done
fi

exit "$WORST"
