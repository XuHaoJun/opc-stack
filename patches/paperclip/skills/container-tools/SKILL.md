---
name: container-tools
description: Install command-line tools inside the OPC stack with nix. Use whenever a needed binary is missing — a compiler, a linter, a database client, an image or video tool, anything not already on PATH. Also covers why apt-get must never be used here.
---

# container-tools — installing what you need

## The rule

Missing tool? `nix-add nixpkgs#<tool>`. **Never `apt-get install`.**

```bash
nix-add nixpkgs#ffmpeg          # one
nix-add nixpkgs#pandoc nixpkgs#imagemagick   # several at once
nix-list                        # what the stack already has
```

Search for a package name at <https://search.nixos.org/packages>, or from the
shell: `nix search nixpkgs <term>`.

## Why not apt

apt writes into the container's own filesystem layer. That layer is discarded
on the next image rebuild or container recreate, so the tool disappears and
the next session hits the same missing binary with nothing explaining why. It
also needs root, which you are not.

`nix-add` writes to the shared nix volume. Two consequences worth knowing:

- **It survives.** Restarts, recreates, redeploys — the tool stays.
- **It is stack-wide.** Every container shares one nix store and one shared
  profile, so anything you install shows up for every other agent too. That is
  deliberate: nobody installs the same thing twice. It also means you are
  changing a shared environment — install what you need, not a pile of
  things you might.

## When it does not work

**`nix-add` reports a file conflict.** Something already provides that binary
(commonly a different version of the same package). Do not force it — a
shared profile means overriding someone else's version affects them. Report
the conflict and what you needed instead.

**The tool installs but the old version still runs.** Eleven tools are
installed at the image level and deliberately win over the shared profile on
PATH: `rg` `jq` `fd` `bat` `just` `mise` `gh` `htop` `ps` `ss` `lsof`.
Re-installing one of these has no effect by design. Needing a different
version of one is a request for a human, not something to work around.

**`nix-add: not found` or the install fails to reach the daemon.** The
stack's `nix-daemon` service is down. Already-installed tools keep working;
new installs do not. Report it — you cannot fix it from inside your container.

## Language toolchains

For language runtimes and their versions (node, python, rust, go), prefer
`mise` where the project already uses it — it is version-aware per project in
a way a single shared nix profile is not. Use nix for everything else.

## Need a service, not a tool?

A daemon (database, cache, queue, vector store) is not a tool install. Lease it:
`devenv` for shared modern backends, `podenv` for a whole container of your own
(any image, including very old versions). The **podenv** skill holds the
decision table for which one.
