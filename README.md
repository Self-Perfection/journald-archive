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
/var/log/journal_combined/         queried via `journalctl-all`
```

## Components

The runtime is distribution-agnostic:

- [`sbin/journald-archive`](sbin/journald-archive) — the mv-and-vacuum script,
  run by the timer.
- [`bin/journalctl-all`](bin/journalctl-all) — convenience wrapper that runs
  `journalctl` against the combined view (with bash and zsh completion).
- [`systemd/`](systemd) — a oneshot service, its 30-minute timer, and the two
  mount units (archive btrfs loopback + mergerfs union).

See [`journald-archive(8)`](packaging/deb/debian/journald-archive.8) and
[`journalctl-all(1)`](packaging/deb/debian/journalctl-all.1) for manual pages.

## Installation

Installation is handled per-distribution under [`packaging/`](packaging):

| Method | Target | Status |
|--------|--------|--------|
| [Debian package](packaging/deb) | Debian, Ubuntu | available |
| RPM / Arch / `install.sh` | others | planned |

For Debian/Ubuntu, see [`packaging/deb/README.md`](packaging/deb/README.md):
build a `.deb`, copy it to the target, and `apt install` it. On install you
are asked for the archive size; sensible defaults are computed from the
current journal size.

## Configuration

Runtime config lives in `/etc/default/journald-archive`:

```ini
ARCHIVE_MOUNT="/var/log/journal_archive"
ARCHIVE_FILE="/var/log/journal_archive.btrfs"
VACUUM_SIZE_GIB=10
```

Edit and run `systemctl restart journald-archive.timer` (or just wait for the
next tick) — the values are re-read on every script invocation.

To change the loopback file size after install: stop the mount, resize the
file (`fallocate` or `truncate`), `btrfs filesystem resize` from inside a
temporary mount, then restart the mount unit.

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
journalctl-all -u nginx --since 2025-01-01
```

`journalctl-all` is a thin wrapper for
`journalctl --directory=/var/log/journal_combined`; it takes all the same
options and tab-completes like `journalctl`.

## Maintenance notes

- After `systemctl restart systemd-journald`, journald writes to
  `/run/log/journal` until something sends it `SIGUSR1`. To restore persistent
  journaling: `systemctl restart systemd-journal-flush`. This is upstream
  systemd behavior — this tool deliberately does not auto-flush, so you can do
  maintenance with logs going to tmpfs.

- The archive timer skips files younger than 60 seconds to avoid racing
  journald during rotation.

- `journalctl --vacuum-size` operates on *logical* (uncompressed) bytes; the
  loopback file size caps the *physical* on-disk usage. As long as
  vacuum-size ≥ loopback, btrfs cannot hit ENOSPC.

- This tool does NOT modify `/etc/systemd/journald.conf`. Set
  `SystemMaxFileSize` etc. to your own taste.

- The loopback file `/var/log/journal_archive.btrfs` holds your archived
  journals and is never removed by uninstallation. Delete it manually if you
  no longer want the history.
