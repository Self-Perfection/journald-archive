# journald-archive

Tiered storage for systemd-journald logs.

Moves rotated journal files from `/var/log/journal/` (hot, uncompressed) to
`/var/log/journal_archive/` (cold, btrfs+zstd) on a 30-minute systemd timer.
A read-only mergerfs union exposes both tiers at `/var/log/journal_combined/`
for full-history queries via `journalctl -D /var/log/journal_combined`.

## Why

When `/var/log/journal/` accumulates hundreds of journal files, every
`journalctl` invocation scans them all — sometimes for minutes before any
output appears. In typical use only the most recent logs are needed, so the
hot tier stays small (fast) while older files are kept compressed in a
separate archive (cheap to store, slow but rarely accessed).

## Architecture

```
/var/log/journal/                  rootfs, no compression — hot tier
                                   (systemd-journald writes here directly)
        ↓ timer moves *@*.journal
/var/log/journal_archive.btrfs     loopback file on rootfs
   │  mount: compress-force=zstd:8
   ▼
/var/log/journal_archive/          cold tier — vacuum-size cap

mergerfs read-only:
   /var/log/journal=RO
   /var/log/journal_archive=RO
        ↓
/var/log/journal_combined/         for journalctl -D /var/log/journal_combined
```

## Build

### Host requirements

A Debian/Ubuntu machine with the toolchain installed:

```bash
make install-deps     # apt install debhelper dpkg-dev devscripts fakeroot lintian
```

Or manually:
```bash
sudo apt install debhelper dpkg-dev fakeroot
# Optional but useful:
sudo apt install devscripts lintian
```

### Building

```bash
make build            # → ../journald-archive_0.1.0_all.deb
make lint             # run lintian on the built deb
make clean            # remove build artifacts
```

Under the hood `make build` runs `dpkg-buildpackage -us -uc -b`:
- `-us` — don't sign source
- `-uc` — don't sign changes
- `-b`  — binary-only build (no source tarball)

The `.deb` lands in the parent directory by convention.

## Install

```bash
scp ../journald-archive_*.deb root@host:/tmp/
ssh root@host 'apt install /tmp/journald-archive_*.deb'
```

(Using `apt install` instead of `dpkg -i` pulls in `mergerfs` and
`btrfs-progs` automatically if missing.)

On install, you will be asked for the loopback file size (default
computed from the current `/var/log/journal/` size, divided by 5 and
rounded up to GiB). The vacuum-size default is 5× the loopback.

For unattended install:
```bash
DEBIAN_FRONTEND=noninteractive apt install /tmp/journald-archive_*.deb
```

## Configuration

Runtime config lives in `/etc/default/journald-archive`:
```ini
ARCHIVE_MOUNT="/var/log/journal_archive"
ARCHIVE_FILE="/var/log/journal_archive.btrfs"
VACUUM_SIZE_GIB=10
```

Edit and run `systemctl restart journald-archive.timer` (or just wait for
the next tick) — the values are re-read on every script invocation.

To change the loopback file size after install: stop the mount, resize
the file (`fallocate` or `truncate`), `btrfs filesystem resize` from
inside a temporary mount, then restart the mount unit. Or just remove
the file and reinstall with new debconf answers.

To change the timer interval, drop in:
```ini
# /etc/systemd/system/journald-archive.timer.d/override.conf
[Timer]
OnUnitActiveSec=15min
```
then `systemctl daemon-reload && systemctl restart journald-archive.timer`.

## Usage

```bash
# Recent logs only — fast (only hot tier)
journalctl -u nginx -n 100

# Full history including archive — slower but complete
journalctl -D /var/log/journal_combined -u nginx --since 2025-01-01
```

## Maintenance notes

- After `systemctl restart systemd-journald`, journald writes to
  `/run/log/journal` until something sends it `SIGUSR1`. To restore
  persistent journaling: `systemctl restart systemd-journal-flush`.
  This is upstream systemd behavior — this package deliberately does
  not auto-flush, so you can do maintenance with logs going to tmpfs.

- The archive timer skips files younger than 60 seconds to avoid racing
  journald during rotation.

- `journalctl --vacuum-size` operates on *logical* (uncompressed) bytes,
  the loopback file size caps the *physical* on-disk usage. As long as
  vacuum-size ≥ loopback, btrfs cannot hit ENOSPC.

- The package does NOT modify `/etc/systemd/journald.conf`. Set
  `SystemMaxFileSize` etc. to your own taste.

## Uninstall

```bash
apt remove journald-archive          # stops timer, leaves mounts & data
apt purge journald-archive           # also removes /etc/default/journald-archive
```

The loopback file `/var/log/journal_archive.btrfs` is **never** removed
automatically — it contains your archived journals. Delete manually if
you no longer want them.

## Layout

```
debian/                       Debian packaging metadata
sbin/journald-archive         The mv-and-vacuum script
systemd/*.service             oneshot service that runs the script
systemd/*.timer               30-min timer for the service
systemd/*.mount               Mount units for archive btrfs + mergerfs
Makefile                      Build helpers
```
