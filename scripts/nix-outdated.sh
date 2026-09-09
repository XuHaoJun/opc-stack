#!/usr/bin/env bash
# Report Nix seed pins, nixpkgs channel/package updates, and live runtime drift.

#   scripts/nix-outdated.sh [--skip-runtime]
#
# This is deliberately separate from scripts/outdated.sh. The upstream report
# compares Git tags without requiring a running stack; this report compares a
# Nix image seed with the persistent opc-nix volume and therefore can inspect a
# live nix-daemon when requested.
#
# Exit status:
#   0  checked inputs are current and the live profile matches the seed
#   1  an update or runtime/seed drift needs attention
#   2  the report is incomplete or the seed declarations disagree
set -uo pipefail
cd "$(dirname "$0")/.."

NIX_SEED_DOCKERFILE=patches/nix-seed/Dockerfile
NIX_DAEMON_FILE=patches/nix-seed/opc-nix-daemon.sh
NIXPKGS_REPO="${NIXPKGS_REPO:-https://github.com/NixOS/nixpkgs.git}"
NIXPKGS_CHANNEL="${NIXPKGS_CHANNEL:-nixos-unstable}"
NIX_RELEASE_API="${NIX_RELEASE_API:-https://api.github.com/repos/NixOS/nix/tags?per_page=100}"
NIX_RUNTIME_SERVICE="${NIX_RUNTIME_SERVICE:-nix-daemon}"
NIX_PROFILE="${NIX_PROFILE:-/nix/var/nix/profiles/per-user/root/profile}"
NIX_BIN="${NIX_BIN:-/nix/var/nix/profiles/default/bin/nix}"

usage() {
    echo "usage: scripts/nix-outdated.sh [--skip-runtime]" >&2
    echo "  default: inspect the live nix-daemon and root system profile" >&2
    echo "  --skip-runtime: report source pins without contacting Docker" >&2
}

CHECK_RUNTIME=1
for arg in "$@"; do
    case "$arg" in
        --skip-runtime) CHECK_RUNTIME=0 ;;
        -h|--help) usage; exit 2 ;;
        *)
            echo "unknown option '$arg'" >&2
            usage
            exit 2
            ;;
    esac
done

WORST=0
OUTDATED=0
WARNINGS=()

bump() {
    [ "$1" -gt "$WORST" ] && WORST="$1"
    return 0
}

warn() {
    WARNINGS+=("$1")
}

mark_outdated() {
    OUTDATED=$((OUTDATED + 1))
    bump 1
}

unique_lines() {
    sed '/^[[:space:]]*$/d' | awk '!seen[$0]++'
}

numeric_version() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)+$ ]]
}

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

ver_gt() {
    awk -v a="$1" -v b="$2" "$VCMP_AWK"'
      BEGIN { exit (vcmp(a, b) > 0) ? 0 : 1 }
    '
}

dockerfile_nixpkgs_pins() {
    awk '
      /github:NixOS\/nixpkgs\/[0-9a-fA-F]+#/ {
        line = $0
        sub(/^.*github:NixOS\/nixpkgs\//, "", line)
        sub(/#.*/, "", line)
        if (line != "") print line
      }
    ' "$NIX_SEED_DOCKERFILE" | unique_lines
}

dockerfile_seed_tools() {
    awk '
      /github:NixOS\/nixpkgs\/[0-9a-fA-F]+#/ {
        line = $0
        sub(/^.*github:NixOS\/nixpkgs\/[0-9a-fA-F]+#/, "", line)
        sub(/[[:space:]].*$/, "", line)
        if (line ~ /^[A-Za-z0-9_.+:-]+$/) print line
      }
    ' "$NIX_SEED_DOCKERFILE" | unique_lines
}

daemon_nixpkgs_pins() {
    sed -n -E \
        's/^[[:space:]]*NIXPKGS=github:NixOS\/nixpkgs\/([0-9a-fA-F]+).*$/\1/p' \
        "$NIX_DAEMON_FILE" | unique_lines
}

daemon_seed_tools() {
    value="$(awk -F'"' '/^[[:space:]]*SEED_TOOLS=/ { print $2; exit }' "$NIX_DAEMON_FILE")"
    [ -n "$value" ] || return 0
    printf '%s\n' "$value" | tr ' ' '\n' | sed -n -E 's/^[^:]+:(.+)$/\1/p' | unique_lines
}

add_row() {
    ROWS+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4")
}

ROWS=()

# ── static seed declarations ────────────────────────────────────────────────
seed_nix_version=""
if [ ! -f "$NIX_SEED_DOCKERFILE" ]; then
    warn "$NIX_SEED_DOCKERFILE is missing"
    bump 2
else
    mapfile -t nix_versions < <(
        sed -n -E \
            's#.*releases\.nixos\.org/nix/nix-([0-9]+(\.[0-9]+)+)/install.*#\1#p' \
            "$NIX_SEED_DOCKERFILE" | unique_lines
    )
    if [ "${#nix_versions[@]}" -ne 1 ] || ! numeric_version "${nix_versions[0]:-}"; then
        warn "could not read exactly one Nix version from $NIX_SEED_DOCKERFILE"
        bump 2
    else
        seed_nix_version="${nix_versions[0]}"
    fi
fi

docker_pin=""
daemon_pin=""
if [ ! -f "$NIX_SEED_DOCKERFILE" ]; then
    :
elif ! mapfile -t docker_pins < <(dockerfile_nixpkgs_pins); then
    warn "could not read nixpkgs pins from $NIX_SEED_DOCKERFILE"
    bump 2
elif [ "${#docker_pins[@]}" -ne 1 ]; then
    warn "could not read exactly one nixpkgs pin from $NIX_SEED_DOCKERFILE"
    bump 2
else
    docker_pin="${docker_pins[0]}"
fi

if [ ! -f "$NIX_DAEMON_FILE" ]; then
    warn "$NIX_DAEMON_FILE is missing"
    bump 2
else
    if ! mapfile -t daemon_pins < <(daemon_nixpkgs_pins); then
        warn "could not read nixpkgs pins from $NIX_DAEMON_FILE"
        bump 2
    elif [ "${#daemon_pins[@]}" -ne 1 ]; then
        warn "could not read exactly one nixpkgs pin from $NIX_DAEMON_FILE"
        bump 2
    else
        daemon_pin="${daemon_pins[0]}"
    fi
fi

if [ -n "$docker_pin" ] && [ -n "$daemon_pin" ] && [ "$docker_pin" != "$daemon_pin" ]; then
    warn "Dockerfile and daemon nixpkgs pins differ ($docker_pin vs $daemon_pin)"
    bump 2
fi

if [ -f "$NIX_SEED_DOCKERFILE" ] && [ -f "$NIX_DAEMON_FILE" ]; then
    docker_tools="$(dockerfile_seed_tools)"
    daemon_tools="$(daemon_seed_tools)"
    if [ -z "$docker_tools" ] || [ -z "$daemon_tools" ]; then
        warn "could not read the seed tool list from both Nix declarations"
        bump 2
    elif [ "$(printf '%s\n' "$docker_tools" | sort -u)" != \
          "$(printf '%s\n' "$daemon_tools" | sort -u)" ]; then
        warn "Dockerfile and daemon seed tool lists differ"
        bump 2
    fi
else
    docker_tools=""
    daemon_tools=""
fi

# The daemon list is the authoritative attr list for live profile comparison.
mapfile -t seed_attrs < <(printf '%s\n' "$daemon_tools" | sed '/^$/d')

# ── latest nixpkgs channel revision ──────────────────────────────────────────
nixpkgs_head=""
nixpkgs_latest_display="?"
nixpkgs_status="?"
if [ -n "$docker_pin" ]; then
    nixpkgs_ref="refs/heads/$NIXPKGS_CHANNEL"
    if ! nixpkgs_remote="$(git ls-remote --heads "$NIXPKGS_REPO" "$nixpkgs_ref" 2>&1)"; then
        warn "could not query nixpkgs channel $NIXPKGS_CHANNEL ($(printf '%s' "$nixpkgs_remote" | awk 'NF { line=$0 } END { print line }'))"
        bump 2
    else
        nixpkgs_head="$(printf '%s\n' "$nixpkgs_remote" | awk -v ref="$nixpkgs_ref" '$2 == ref { print $1; exit }')"
        if ! [[ "$nixpkgs_head" =~ ^[0-9a-fA-F]{40}$ ]]; then
            warn "nixpkgs channel $NIXPKGS_CHANNEL returned no usable commit"
            bump 2
        elif [[ "$nixpkgs_head" == "$docker_pin"* ]]; then
            nixpkgs_latest_display="$docker_pin"
            nixpkgs_status="-"
        else
            nixpkgs_latest_display="$nixpkgs_head"
            nixpkgs_status="newer"
            mark_outdated
        fi
    fi
else
    warn "nixpkgs pin is unavailable, so the channel cannot be checked"
    bump 2
fi
add_row "nixpkgs" "${docker_pin:-?}" "$nixpkgs_latest_display" "$nixpkgs_status"

# ── latest stable Nix release ────────────────────────────────────────────────
latest_nix_version=""
nix_status="?"
if ! release_json="$(curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: opc-stack-nix-outdated' "$NIX_RELEASE_API" 2>&1)"; then
    warn "could not query the latest Nix release ($(printf '%s' "$release_json" | awk 'NF { line=$0 } END { print line }'))"
    bump 2
else
    latest_nix_version=""
    mapfile -t nix_release_tags < <(
        printf '%s' "$release_json" |
            awk -F'"' '/"tag_name"[[:space:]]*:/ || /"name"[[:space:]]*:/ { print $4 }'
    )
    for release_tag in "${nix_release_tags[@]}"; do
        release_tag="${release_tag#v}"
        if numeric_version "$release_tag" && {
            [ -z "$latest_nix_version" ] || ver_gt "$release_tag" "$latest_nix_version"
        }; then
            latest_nix_version="$release_tag"
        fi
    done
    if ! numeric_version "$latest_nix_version"; then
        warn "Nix tags API returned no stable numeric tag"
        bump 2
    elif [ -z "$seed_nix_version" ]; then
        nix_status="?"
    elif ver_gt "$latest_nix_version" "$seed_nix_version"; then
        nix_status="newer"
        mark_outdated
    else
        nix_status="-"
    fi
fi
add_row "nix" "${seed_nix_version:-?}" "${latest_nix_version:-?}" "$nix_status"

# ── live runtime ─────────────────────────────────────────────────────────────
profile_status="skipped"
profile_current="-"
profile_latest="-"
live_nix_status="skipped"
live_nix_current="-"
live_nix_latest="-"
live_nix_version=""
runtime_nix_available=0
profile_available=0
declare -A profile_urls=()
if [ "$CHECK_RUNTIME" -eq 0 ]; then
    echo "live root profile check skipped (--skip-runtime)"
else
    runtime_version_output=""
    if ! runtime_version_output="$(docker compose exec -T "$NIX_RUNTIME_SERVICE" "$NIX_BIN" --version 2>&1)"; then
        warn "could not inspect live Nix runtime via docker compose exec"
        live_nix_status="?"
        live_nix_current="?"
        live_nix_latest="${seed_nix_version:-?}"
        bump 2
    else
        live_nix_version="$(printf '%s\n' "$runtime_version_output" | sed -n -E 's/.*Nix\)[[:space:]]+([0-9]+(\.[0-9]+)+).*/\1/p' | awk 'NF { print; exit }')"
        if numeric_version "$live_nix_version"; then
            runtime_nix_available=1
        fi
        if ! numeric_version "$live_nix_version"; then
            warn "live Nix runtime returned no readable version"
            live_nix_status="?"
            live_nix_current="?"
            live_nix_latest="${seed_nix_version:-?}"
            bump 2
        elif [ -z "$seed_nix_version" ]; then
            live_nix_status="?"
            live_nix_current="$live_nix_version"
            live_nix_latest="?"
        elif [ "$live_nix_version" != "$seed_nix_version" ]; then
            warn "live Nix runtime is $live_nix_version but the seed pins $seed_nix_version"
            live_nix_status="drift"
            live_nix_current="$live_nix_version"
            live_nix_latest="$seed_nix_version"
            mark_outdated
        else
            live_nix_status="-"
            live_nix_current="$live_nix_version"
            live_nix_latest="$seed_nix_version"
        fi
    fi
fi
add_row "live-nix" "$live_nix_current" "$live_nix_latest" "$live_nix_status"

if [ "$CHECK_RUNTIME" -ne 0 ]; then
    profile_json=""
    if ! profile_json="$(docker compose exec -T "$NIX_RUNTIME_SERVICE" "$NIX_BIN" profile list --json --profile "$NIX_PROFILE" 2>&1)"; then
        warn "could not inspect live root Nix profile"
        bump 2
    elif ! command -v jq >/dev/null 2>&1; then
        warn "jq is required to inspect the live Nix profile"
        bump 2
    else
        if ! profile_rows="$(printf '%s' "$profile_json" | jq -r '.elements | to_entries[] | [.key, (.value.originalUrl // "")] | @tsv' 2>&1)"; then
            warn "live root Nix profile was not valid JSON"
            bump 2
        else
            while IFS=$'\t' read -r profile_name profile_url; do
                [ -n "$profile_name" ] || continue
                profile_urls["$profile_name"]="$profile_url"
            done <<< "$profile_rows"
            profile_available=1

            expected_url=""
            [ -n "$docker_pin" ] && expected_url="github:NixOS/nixpkgs/$docker_pin"
            profile_mismatch=0
            profile_missing=0
            for attr in "${seed_attrs[@]}"; do
                [ -n "$attr" ] || continue
                actual_url="${profile_urls[$attr]-}"
                if [ -z "$actual_url" ]; then
                    profile_missing=1
                    continue
                fi
                if [ -n "$expected_url" ] && [ "$actual_url" != "$expected_url" ]; then
                    profile_mismatch=1
                fi
            done

            if [ "$profile_missing" -eq 1 ]; then
                profile_status="missing"
                profile_current="?"
                profile_latest="${docker_pin:-?}"
                warn "live root profile is missing one or more declared seed tools"
                bump 2
            elif [ "$profile_mismatch" -eq 1 ]; then
                profile_status="drift"
                profile_current="different-pin"
                profile_latest="${docker_pin:-?}"
                warn "live root profile differs from seed pin"
                mark_outdated
            else
                profile_status="-"
                profile_current="${docker_pin:-?}"
                profile_latest="${docker_pin:-?}"
                echo "live root profile matches seed pin"
            fi
        fi
    fi
fi
add_row "profile" "$profile_current" "$profile_latest" "$profile_status"

# ── per-seed package versions ────────────────────────────────────────────────
# The package rows are deliberately evaluated from the exact profile pin and
# the candidate channel pin. A nixpkgs revision can move without changing
# every package, so the summary row alone is not enough for an operator.
if [ "$CHECK_RUNTIME" -eq 0 ]; then
    for attr in "${seed_attrs[@]}"; do
        [ -n "$attr" ] || continue
        add_row "$attr" "-" "-" "skipped"
    done
elif [ "$runtime_nix_available" -eq 0 ] || [ "$profile_available" -eq 0 ] || [ -z "$nixpkgs_head" ]; then
    for attr in "${seed_attrs[@]}"; do
        [ -n "$attr" ] || continue
        add_row "$attr" "?" "?" "?"
    done
else
    package_current_pin="$docker_pin"
    profile_pin=""
    profile_pin_conflict=0
    for attr in "${seed_attrs[@]}"; do
        [ -n "$attr" ] || continue
        actual_url="${profile_urls[$attr]-}"
        if [[ "$actual_url" =~ ^github:NixOS/nixpkgs/([0-9a-fA-F]+)$ ]]; then
            candidate_pin="${BASH_REMATCH[1]}"
            if [ -z "$profile_pin" ]; then
                profile_pin="$candidate_pin"
            elif [ "$profile_pin" != "$candidate_pin" ]; then
                profile_pin_conflict=1
            fi
        else
            profile_pin_conflict=1
        fi
    done
    if [ "$profile_pin_conflict" -eq 0 ] && [ -n "$profile_pin" ]; then
        package_current_pin="$profile_pin"
    else
        package_current_pin=""
    fi

    package_eval_ok=0
    package_eval_json=""
    if [ -n "$package_current_pin" ]; then
        package_expr="let current = (builtins.getFlake \"github:NixOS/nixpkgs/$package_current_pin\").legacyPackages.x86_64-linux; latest = (builtins.getFlake \"github:NixOS/nixpkgs/$nixpkgs_head\").legacyPackages.x86_64-linux; version = package: let result = builtins.tryEval package.version; in if result.success then result.value else null; in {"
        for attr in "${seed_attrs[@]}"; do
            [ -n "$attr" ] || continue
            package_expr+="\"$attr\" = { current = version current.\"$attr\"; latest = version latest.\"$attr\"; };"
        done
        package_expr+='}'

        if package_eval_json="$(docker compose exec -T "$NIX_RUNTIME_SERVICE" "$NIX_BIN" eval --json --expr "$package_expr" --impure 2>/dev/null)"; then
            if printf '%s' "$package_eval_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
                package_eval_ok=1
            fi
        fi
    fi

    if [ "$package_eval_ok" -eq 0 ]; then
        warn "could not evaluate seed package versions in nixpkgs"
        bump 2
        for attr in "${seed_attrs[@]}"; do
            [ -n "$attr" ] || continue
            add_row "$attr" "?" "?" "?"
        done
    else
        package_rows="$(printf '%s' "$package_eval_json" | jq -r 'to_entries[] | [.key, (.value.current // ""), (.value.latest // "")] | @tsv')"
        declare -A package_current_versions=()
        declare -A package_latest_versions=()
        while IFS=$'\t' read -r package_name package_current package_latest; do
            [ -n "$package_name" ] || continue
            package_current_versions["$package_name"]="$package_current"
            package_latest_versions["$package_name"]="$package_latest"
        done <<< "$package_rows"

        for attr in "${seed_attrs[@]}"; do
            [ -n "$attr" ] || continue
            package_current="${package_current_versions[$attr]-}"
            package_latest="${package_latest_versions[$attr]-}"
            if [ -z "$package_current" ] || [ -z "$package_latest" ]; then
                add_row "$attr" "${package_current:-?}" "${package_latest:-?}" "?"
                bump 2
            elif [ "$package_current" = "$package_latest" ]; then
                add_row "$attr" "$package_current" "$package_latest" "-"
            else
                add_row "$attr" "$package_current" "$package_latest" "newer"
                mark_outdated
            fi
        done
    fi
fi


# ── table ────────────────────────────────────────────────────────────────────
HEADER=("surface" "current" "latest" "status")
widths=(0 0 0 0)
for i in 0 1 2 3; do widths[i]="${#HEADER[$i]}"; done
for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r -a cells <<< "$row"
    for i in 0 1 2 3; do
        [ "${#cells[$i]}" -gt "${widths[$i]}" ] && widths[i]="${#cells[$i]}"
    done
done
printf '%-*s  %-*s  %-*s  %s\n' \
    "${widths[0]}" "${HEADER[0]}" "${widths[1]}" "${HEADER[1]}" \
    "${widths[2]}" "${HEADER[2]}" "${HEADER[3]}"
for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r -a cells <<< "$row"
    printf '%-*s  %-*s  %-*s  %s\n' \
        "${widths[0]}" "${cells[0]}" "${widths[1]}" "${cells[1]}" \
        "${widths[2]}" "${cells[2]}" "${cells[3]}"
done

echo
if [ "$OUTDATED" -eq 0 ]; then
    if [ "$WORST" -eq 0 ]; then
        if [ "$CHECK_RUNTIME" -eq 0 ]; then
            echo "Nix seed inputs are aligned; live runtime and package versions were skipped."
        else
            echo "Nix seed and live runtime/package versions are aligned with the checked inputs."
        fi
    else
        echo "Nix report incomplete; no clean verdict."
    fi
else
    echo "$OUTDATED Nix input/runtime/package item(s) need attention:"
    echo "  1. upgrade the live root profile first, then run the stack verification."
    echo "  2. after verification, copy the tested pin into patches/nix-seed/Dockerfile and patches/nix-seed/opc-nix-daemon.sh."
    echo "  3. rebuild the seed and service images; rebuilding does not rewrite an existing opc-nix volume."
    if [ -n "$docker_pin" ] && [ "${#seed_attrs[@]}" -gt 0 ]; then
        echo
        echo "  explicit root-profile migration (replace the revision with the tested commit):"
        printf '    docker compose exec -u root %s %s profile remove --profile %s' \
            "$NIX_RUNTIME_SERVICE" "$NIX_BIN" "$NIX_PROFILE"
        printf ' %s' "${seed_attrs[@]}"
        echo
        printf '    docker compose exec -u root %s %s profile add --profile %s \\\n' \
            "$NIX_RUNTIME_SERVICE" "$NIX_BIN" "$NIX_PROFILE"
        for attr in "${seed_attrs[@]}"; do
            printf '      github:NixOS/nixpkgs/<tested-revision>#%s' "$attr"
            if [ "$attr" != "${seed_attrs[${#seed_attrs[@]}-1]}" ]; then
                printf ' \\\n'
            else
                printf '\n'
            fi
        done
    fi
fi

if [ "${#WARNINGS[@]}" -gt 0 ]; then
    echo >&2
    for warning in "${WARNINGS[@]}"; do
        echo "warning: $warning" >&2
    done
fi

exit "$WORST"
