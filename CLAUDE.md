# CLAUDE.md

Guidance for working in this repo.

## What this is

`journald-archive` moves rotated systemd-journal files from the hot tier
(`/var/log/journal/`) into a compressed btrfs loopback archive on a timer, and
exposes a merged read-only view via mergerfs. See [README.md](README.md).

## Layout

- The **portable core** lives at the repo root and is distribution-agnostic:
  `libexec/journald-archive` (the timer helper), `bin/journalctl-all`,
  `systemd/`, `bash-completion/`, `zsh-completion/`.
- `packaging/` holds **wrappers** that stage that core into a package
  (`packaging/deb/` is the only one implemented). Packaging never copies the
  core — `packaging/deb/build.sh` stages it into a temp tree and builds there.
- `tests/` is dev-only functional tests; it is **not** shipped in the `.deb`.

## Shells

`libexec/journald-archive` is `#!/bin/bash` on purpose (process substitution,
`read -d`). Everything else that doesn't need bash — `bin/journalctl-all` and
the Debian maintainer scripts — is `#!/bin/sh`. Don't add a `bash` dependency:
it is Essential.

## Building and testing

Build and functional-test on the disposable root VM (systemd, loop devices,
btrfs) — **not** in a container, and not via CI:

```bash
make -C packaging/deb build      # -> packaging/deb/dist/*.deb
sudo tests/eviction.sh           # functional regression test (needs root)
```

A clean build and a "service exited 0" smoke test are **not** sufficient. The
archive's central path (eviction) only runs when the archive is actually full;
it was broken for months while empty-archive smoke tests stayed green (0.3.4).
When a fix touches a path that only runs under real load, add a test under
`tests/`.

GitHub Actions is **release-only** (clean-room build from a pushed `v*` tag); it
does not run the functional tests.

## Releasing

Follow [RELEASING.md](RELEASING.md). In short: run the VM tests, finalize the
top `packaging/deb/debian/changelog` entry (`unstable`, not `UNRELEASED`,
version matching the tag), then commit, `git tag v<version>`, and push the tag.
