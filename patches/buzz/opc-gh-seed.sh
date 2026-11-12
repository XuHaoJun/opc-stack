#!/bin/sh
# Frontdoor uses the host's gh login over HTTPS, not its SSH private keys.
# /creds retains host ownership; the agent runs as uid 10000.
opc_gh_env() {
    export GH_CONFIG_DIR="${HERMES_HOME:-/opt/data}/.config/gh"
    export GIT_CONFIG_GLOBAL="${HERMES_HOME:-/opt/data}/.config/git/config"
    export GIT_TERMINAL_PROMPT=0
    export GH_PROMPT_DISABLED=1
}

# Called by the root entrypoint on every boot. Mirror only the gh login and
# generated Git config; refresh rotations and remove revoked source logins.
# These files carry the SAME permissions as the personal host login, not
# read-only GitHub authorization. Never chmod/chown the shared source volume.
opc_gh_seed() {
    opc_gh_env
    _opc_gh_owner="${HERMES_UID:-10000}:${HERMES_GID:-10000}"
    install -d -m 700 -o "${HERMES_UID:-10000}" -g "${HERMES_GID:-10000}" \
        "$GH_CONFIG_DIR" "$(dirname "$GIT_CONFIG_GLOBAL")"
    for _opc_gh_file in hosts.yml config.yml; do
        if [ -f "/creds/gh/$_opc_gh_file" ]; then
            install -m 600 -o "${HERMES_UID:-10000}" -g "${HERMES_GID:-10000}" \
                "/creds/gh/$_opc_gh_file" "$GH_CONFIG_DIR/$_opc_gh_file"
        else
            rm -f "$GH_CONFIG_DIR/$_opc_gh_file"
        fi
    done
    if [ -f /creds/git/config ]; then
        install -m 600 /creds/git/config "$GIT_CONFIG_GLOBAL"
    else
        install -m 600 /dev/null "$GIT_CONFIG_GLOBAL"
    fi
    git config --file "$GIT_CONFIG_GLOBAL" --replace-all \
        credential.https://github.com.helper ''
    git config --file "$GIT_CONFIG_GLOBAL" --add \
        credential.https://github.com.helper '!gh auth git-credential'
    # gh may inherit git_protocol: ssh. Git's rewrite also covers existing
    # SSH remotes, without adding SSH or exposing the host's private keys.
    git config --file "$GIT_CONFIG_GLOBAL" --replace-all \
        url.https://github.com/.insteadOf 'git@github.com:'
    git config --file "$GIT_CONFIG_GLOBAL" --add \
        url.https://github.com/.insteadOf 'ssh://git@github.com/'
    chown "$_opc_gh_owner" "$GIT_CONFIG_GLOBAL"
    chmod 600 "$GIT_CONFIG_GLOBAL"
    if [ ! -s "$GH_CONFIG_DIR/hosts.yml" ]; then
        echo "[gh-seed] WARNING: no synced gh login; private GitHub access unavailable" >&2
    fi
    unset _opc_gh_owner _opc_gh_file
}
