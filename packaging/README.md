# Packaging

journald-archive's runtime is just a shell script plus a handful of systemd
units, living at the repo root in [`sbin/`](../sbin) and
[`systemd/`](../systemd). That core is distribution-agnostic; everything in
this directory is a *wrapper* that takes the same core and packages it for a
particular ecosystem.

Each method assembles its build tree from the shared core rather than carrying
its own copy, so there is a single source of truth for the script and units.

## Methods

| Method | Target | Status | Directory |
|--------|--------|--------|-----------|
| Debian package | Debian, Ubuntu | available | [`deb/`](deb) |
| RPM package | Fedora, RHEL, openSUSE | planned | — |
| Arch (PKGBUILD) | Arch, derivatives | planned | — |
| `install.sh` | any systemd distro | planned | — |

## Adding a new method

Create a subdirectory here, and have its build step pull the core directories
from the repo root (the `deb/` method does this in
[`deb/build.sh`](deb/build.sh) by staging into a temp tree). Install paths
should match what the core expects:

- `sbin/journald-archive` → `/usr/sbin/journald-archive`
- `bin/journalctl-all` → `/usr/bin/journalctl-all`
- `bash-completion/journalctl-all` → `/usr/share/bash-completion/completions/journalctl-all`
- `systemd/*` → `/usr/lib/systemd/system/`

and the package should depend on `systemd`, `mergerfs`, and `btrfs-progs`.
