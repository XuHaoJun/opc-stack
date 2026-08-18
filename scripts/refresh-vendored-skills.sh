#!/usr/bin/env bash
# refresh-vendored-skills.sh — pull newer revisions of vendored third-party
# skills under patches/*/skills/*/ that carry a SOURCE manifest.
#
#   scripts/refresh-vendored-skills.sh              # check every vendored skill
#   scripts/refresh-vendored-skills.sh <skill-dir>  # just one
#
# Why these are vendored rather than imported: Paperclip's GitHub importer
# fetches only SKILL.md, so any skill whose SKILL.md dispatches to sibling
# files arrives broken. Vendoring keeps them whole, at the cost of Paperclip's
# update-status drift detection — this script is the replacement for it.
#
# Fetches the tracking ref's current commit, rewrites the files in place, and
# leaves the diff staged in the working tree for you to review. It does NOT
# commit: a third-party skill change is a prompt change for your agents and
# deserves to be read.
set -euo pipefail
cd "$(dirname "$0")/.."

targets=()
if [ $# -gt 0 ]; then
    targets=("$@")
else
    while IFS= read -r m; do targets+=("$(dirname "$m")"); done \
        < <(find patches -mindepth 3 -path '*/skills/*/SOURCE' | sort)
fi
[ ${#targets[@]} -gt 0 ] || { echo "no vendored skills found"; exit 0; }

rc=0
for dir in "${targets[@]}"; do
    src="$dir/SOURCE"
    [ -f "$src" ] || { echo "SKIP $dir (no SOURCE manifest)" >&2; rc=1; continue; }

    repo=$(sed -n 's/^repo=//p' "$src");     path=$(sed -n 's/^path=//p' "$src")
    ref=$(sed -n 's/^ref=//p' "$src");       tracking=$(sed -n 's/^tracking=//p' "$src")
    files=$(sed -n 's/^files=//p' "$src")
    owner_repo=${repo#https://github.com/}

    latest=$(curl -fsS "https://api.github.com/repos/${owner_repo}/commits/${tracking}" \
             | sed -n 's/^  "sha": "\(.*\)",$/\1/p' | head -1)
    [ -n "$latest" ] || { echo "FAIL $dir: could not resolve ${tracking}" >&2; rc=1; continue; }

    if [ "$latest" = "$ref" ]; then
        echo "up to date  $dir  (${ref:0:10})"
        continue
    fi

    echo "UPDATING    $dir  ${ref:0:10} -> ${latest:0:10}"
    for f in $files; do
        curl -fsS "https://raw.githubusercontent.com/${owner_repo}/${latest}/${path}/${f}" \
             -o "$dir/$f" || { echo "FAIL fetching $f" >&2; rc=1; }
    done
    sed -i "s/^ref=.*/ref=${latest}/; s/^fetched=.*/fetched=$(date +%F)/" "$src"
    echo "            review with: git diff -- $dir"
done
exit $rc
