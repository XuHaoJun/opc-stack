#!/bin/sh
# ssh source transform — runs inside host-sync-worker after /src/ssh → /dst/ssh.
#
# Rewrites the ssh config for the container layout and bootstraps host keys.
# NOTE: consumers mount the volume at /creds (opc-gh-seed.sh env contract), so
# path strings baked into the config are /creds/ssh/... — independent of the
# worker staging them at /dst/ssh.
set -eu

D=/dst/ssh

# Rewrite host-layout path segments (~/.ssh/x, /home/u/.ssh/x, $HOME/.ssh/x)
# to /creds/ssh/x so the config works in any container regardless of HOME.
# Applies to IdentityFile, Include, ControlPath…
sed -i -E "s|[^ ]*/\\.ssh/|/creds/ssh/|g" "$D/config" 2>/dev/null || true

# If the config never names a key, give github.com the first key found.
if ! grep -qi "IdentityFile" "$D/config" 2>/dev/null; then
    for k in id_ed25519 id_ecdsa id_rsa; do
        if [ -f "$D/$k" ]; then
            printf "Host github.com\\n  HostName github.com\\n  IdentityFile /creds/ssh/%s\\n  IdentitiesOnly yes\\n" "$k" >> "$D/config"
            break
        fi
    done
fi

# github.com host key (fed via stdin from the runner; empty when absent —
# the host's known_hosts usually already carries it).
if ! grep -q "github.com" "$D/known_hosts" 2>/dev/null; then
    cat >> "$D/known_hosts"
fi

# Containers have no ~/.ssh/known_hosts; without an explicit
# UserKnownHostsFile the pre-seeded keys above are never consulted and ssh
# falls back to TOFU (or fails in BatchMode). Point every host at the
# mirrored file; a host config that already names one survives the sed
# rewrite above and skips this.
if ! grep -q "UserKnownHostsFile" "$D/config" 2>/dev/null; then
    printf "Host *\\n  UserKnownHostsFile /creds/ssh/known_hosts\\n" >> "$D/config"
fi

chmod 700 "$D"
chmod 600 "$D"/* 2>/dev/null || true
chmod 644 "$D"/*.pub "$D/known_hosts" "$D/config" 2>/dev/null || true
