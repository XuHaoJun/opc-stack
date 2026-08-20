#!/bin/sh
# opc-env-value.sh — one .env reader, two consumers.
#
# Sourced by hermes-entrypoint.sh (which needs the function while it
# reconciles a profile's .env) and executed directly by
# scripts/test-scientist.sh (which needs the SAME parse to read the key back
# out of a running container). Those two used to be different code: the
# entrypoint had this parser, the gate had a bare `sed -n 's/^KEY=//p'` — one
# of them with a `head -1`, one without. A gate that parses .env differently
# from the thing that wrote it can go green on a file the writer would read
# as something else (duplicate assignment, `export ` prefix, quotes, inline
# comment), so there is exactly one implementation now and both callers use it.
#
#   . /usr/local/bin/opc-env-value.sh   → defines opc_env_value <file> <name>
#   opc-env-value.sh <file> <name>      → prints the value on stdout
#
# Read one value out of a .env the way hermes parses it (config.py load_env +
# _parse_env_value, and agent/secret_scope.py::_strip_inline_comment for the
# comment handling): comments skipped, an `export ` prefix stripped, last
# assignment wins, an inline `# ...` comment stripped, surrounding quotes
# removed. Comparing raw file text instead would treat a dashboard-written
# `API_SERVER_KEY="…"` as different from the identical unquoted value and
# rewrite + log "refreshed" on every single boot; not stripping the inline
# comment the way upstream does causes the same spurious one-time rewrite for
# `KEY=abc # note` (self-healing on the next boot, but the log then lies
# about why it fired).
#
# Inline-comment rule mirrors _strip_inline_comment exactly: for a value
# starting with a quote, scan for the matching close quote (backslash-escape
# aware for double quotes only, since the writer emits \"/\\ escapes); if
# what follows the close quote, after leading whitespace, starts with `#`,
# keep only through the close quote — otherwise leave the value untouched
# (lenient, not a parse error). For an unquoted value, truncate at the first
# `#` that is preceded by whitespace, so `foo#bar` is kept whole but
# `foo # bar` becomes `foo`, and a value that itself starts with `#` is kept.
opc_env_value() { # <env-file> <name>
    [ -f "$1" ] || return 0
    awk -v want="$2" '
        BEGIN { sq = sprintf("%c", 39); dq = sprintf("%c", 34) }
        {
            line = $0
            sub(/^[ \t]+/, "", line); sub(/[ \t\r]+$/, "", line)
            if (line ~ /^#/ || index(line, "=") == 0) next
            sub(/^export[ \t]+/, "", line)
            k = substr(line, 1, index(line, "=") - 1)
            gsub(/^[ \t]+|[ \t]+$/, "", k)
            if (k != want) next
            v = substr(line, index(line, "=") + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            n = length(v)
            q = substr(v, 1, 1)
            if (n >= 1 && (q == dq || q == sq)) {
                i = 2; closed = 0; closeidx = 0
                while (i <= n) {
                    ch = substr(v, i, 1)
                    if (q == dq && ch == "\\") { i += 2 }
                    else if (ch == q) { closed = 1; closeidx = i; break }
                    else { i++ }
                }
                if (closed) {
                    rest = substr(v, closeidx + 1)
                    gsub(/^[ \t]+/, "", rest)
                    if (substr(rest, 1, 1) == "#") v = substr(v, 1, closeidx)
                    # else: non-comment trailing junk — leave v untouched
                }
                # else: unterminated quote — leave v untouched
            } else if (match(v, /[ \t]+#/) > 0) {
                v = substr(v, 1, RSTART - 1)
            }
            n = length(v)
            if (n >= 2 && ((substr(v, 1, 1) == dq && substr(v, n, 1) == dq) || \
                           (substr(v, 1, 1) == sq && substr(v, n, 1) == sq)))
                v = substr(v, 2, n - 2)
            out = v; found = 1
        }
        END { if (found) print out }
    ' "$1" 2>/dev/null
}
# Executed, not sourced: act as a CLI. Keyed off $0's basename because a
# POSIX shell gives a sourced file no other way to tell — when
# hermes-entrypoint.sh sources this, $0 is still the entrypoint's own path,
# so the case never matches and nothing runs at source time.
case "${0##*/}" in
    opc-env-value.sh)
        [ "$#" -eq 2 ] || { echo "usage: opc-env-value.sh <env-file> <name>" >&2; exit 2; }
        opc_env_value "$1" "$2"
        ;;
esac
