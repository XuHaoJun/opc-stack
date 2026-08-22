#!/usr/bin/env bash
# Export the variables from ./.env into the environment.
#
# `.env` is a docker-compose dotenv file, NOT a shell script. Compose's parser
# accepts unquoted values containing spaces (PAPERCLIP_EXECUTOR_AGENT_NAME=Fullstack
# Engineer), so sourcing the file with `.` splits that line and then tries to
# run `Engineer` — the "command not found" noise this replaces.
#
# The noise was cosmetic, but sourcing is also wrong in a way that is not:
# compose treats $(...) and backticks as literal text, while `.` would EXECUTE
# them. A dotenv file should never be handed to the shell as code.
#
# Parsing rules kept deliberately close to compose's: skip blanks/comments,
# allow an `export ` prefix, strip ONE layer of matching surrounding quotes.
# Values are taken verbatim otherwise — no escape processing, no interpolation.
opc_load_env() {
    local file="${1:-.env}" line key val
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"     # ltrim
        case "$line" in ''|'#'*) continue ;; esac
        line="${line#export }"
        case "$line" in *=*) ;; *) continue ;; esac
        key="${line%%=*}"
        val="${line#*=}"
        case "$key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
        case "$val" in
            '"'*'"') val="${val#\"}"; val="${val%\"}" ;;
            "'"*"'") val="${val#\'}"; val="${val%\'}" ;;
        esac
        export "$key=$val"
    done < "$file"
}
