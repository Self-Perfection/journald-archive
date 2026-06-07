# Debian/Ubuntu package

Builds `journald-archive` into a `.deb` for Debian and Ubuntu.

## How it builds

`dpkg-buildpackage` expects `debian/` to sit at the root of the build tree,
next to the sources it installs. Here the packaging lives under
`packaging/deb/` while the portable core (`sbin/`, `systemd/`) lives at the
repo root. [`build.sh`](build.sh) reconciles this by staging both into a
temporary directory and building there. Nothing is written back into the
source tree; the finished package lands in `dist/`.

## Build

On a Debian/Ubuntu host:

```bash
make install-deps     # build-essential debhelper dpkg-dev fakeroot lintian
make build            # → dist/journald-archive_<version>_all.deb
make lint             # run lintian on the built package (run as non-root)
make clean            # remove dist/
```

`make build` just calls `./build.sh`; run that directly if you prefer.

## Install on a target host

```bash
scp dist/journald-archive_*.deb root@host:/tmp/
ssh root@host 'apt install /tmp/journald-archive_*.deb'
```

Using `apt install` (rather than `dpkg -i`) pulls in `mergerfs` and
`btrfs-progs` automatically if they are missing.

### debconf questions

On first install you are asked two values:

- **Archive loopback file size (GiB)** — the hard *physical* cap of the
  compressed archive. Default computed from the current `/var/log/journal/`
  size assuming a conservative 5x zstd ratio, rounded up to a whole GiB.
- **Logical retention limit (GiB)** — the `journalctl --vacuum-size` cap on
  *uncompressed* journal data. Default is 5x the loopback size.

For an unattended install:

```bash
DEBIAN_FRONTEND=noninteractive apt install /tmp/journald-archive_*.deb
```

To revisit the answers later: `dpkg-reconfigure journald-archive` (note that
the runtime config in `/etc/default/journald-archive` is only generated on
first install and is not overwritten afterwards — edit it directly to change
a live system).

## Uninstall

```bash
apt remove journald-archive    # stop timer/mounts, leave config and data
apt purge journald-archive     # also remove /etc/default/journald-archive
```

The loopback file `/var/log/journal_archive.btrfs` is **never** removed
automatically — it holds your archived journals. Delete it by hand if you no
longer want them.

## Layout

```
build.sh           Out-of-tree staging build (core + debian/ → dist/)
Makefile           Thin wrapper around build.sh + lint/clean/install helpers
debian/            Debian packaging metadata
dist/              Build output (.deb), git-ignored
```
