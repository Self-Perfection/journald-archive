#!/bin/bash
# Regression test for archive eviction.
#
# Guards against the class of bug fixed in 0.3.4: the eviction loop picked the
# oldest journal with `find ... | sort -n | head -1`, and under
# `set -o pipefail` head closing the pipe after one line makes sort die on
# SIGPIPE (141) as soon as the file listing outgrows the ~64 KiB pipe buffer.
# `set -e` then aborted the helper before deleting anything, so a full archive
# never self-evicted. A "service exited 0 on an empty archive" smoke test does
# NOT catch this — eviction only runs when the archive is actually full and
# holds enough files. So this test fills a throwaway archive past the margin and
# asserts the helper frees space and exits 0.
#
# REQUIREMENTS: run as root on a DISPOSABLE machine. It creates a loopback btrfs
# under a temp dir and *temporarily* swaps /etc/default/journald-archive
# (restored on exit). It never touches the real /var/log/journal_archive. See
# the project's build/test VM.
#
# Usage: sudo tests/eviction.sh [path-to-helper]
#   path-to-helper defaults to ../libexec/journald-archive (the working tree),
#   so the test validates the source, no install required.

set -euo pipefail

HELPER="${1:-$(cd "$(dirname "$0")/.." && pwd)/libexec/journald-archive}"
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 2; }
[ -x "$HELPER" ]      || { echo "helper not executable: $HELPER" >&2; exit 2; }

ARCHIVE_MIB=256          # throwaway archive size
FILE_KIB=256             # per-file size; small enough that filling needs
                         # >600 files, so the listing exceeds the 64 KiB pipe
                         # buffer that triggers the bug
MARGIN_MIB=16            # free space the helper must restore

WORK=$(mktemp -d)
IMG="$WORK/archive.btrfs"
MNT="$WORK/mount"
DEFAULTS=/etc/default/journald-archive
BACKUP="$WORK/defaults.bak"
MID=$(cat /etc/machine-id)
SRC="/var/log/journal/$MID"   # the helper exits early unless this exists
created_src=
margin_bytes=$((MARGIN_MIB * 1024 * 1024))

cleanup() {
    set +e
    mountpoint -q "$MNT" && umount "$MNT"
    if [ -f "$BACKUP" ]; then mv -f "$BACKUP" "$DEFAULTS"; else rm -f "$DEFAULTS"; fi
    [ -n "$created_src" ] && rmdir "$SRC" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# Read "Free (estimated)" the same way the helper does, but with -m1 so nothing
# closes the pipe early (this test runs under pipefail too).
free_now() {
    btrfs filesystem usage -b "$MNT" 2>/dev/null \
        | grep -oPm1 'Free \(estimated\):\s+\K[0-9]+'
}

# --- build a throwaway archive that mirrors how the package makes a small one
mkdir -p "$MNT"
fallocate -l "${ARCHIVE_MIB}MiB" "$IMG"
mkfs.btrfs -q --mixed --metadata single --data single "$IMG"
mount -o loop,compress-force=zstd:8 "$IMG" "$MNT"

# --- point the helper at the sandbox (saving the real config)
[ -e "$DEFAULTS" ] && cp -a "$DEFAULTS" "$BACKUP"
mkdir -p "$(dirname "$DEFAULTS")"
cat >"$DEFAULTS" <<EOF
ARCHIVE_MOUNT="$MNT"
ARCHIVE_FILE="$IMG"
FREE_MARGIN_MIB=$MARGIN_MIB
GRACE_MINUTES=0
EOF
[ -d "$SRC" ] || { mkdir -p "$SRC"; created_src=1; }

# --- fill the archive past the margin with incompressible, journal-named files
DST="$MNT/$MID"
mkdir -p "$DST"
i=0
while :; do
    seq=$(printf '%016x' $((0x11d2235 + i)))
    tail=$(printf '%016x' $((0x64a58ec789800 + i * 1000)))
    f="$DST/system@5b56bccf4e4b43f3930fcf617d86485c-$seq-$tail.journal"
    head -c $((FILE_KIB * 1024)) /dev/urandom > "$f"
    touch -d "2026-01-01 +$i minutes" "$f"   # distinct, increasing mtimes
    i=$((i + 1))
    [ "$(free_now)" -lt "$margin_bytes" ] && break
    [ "$i" -gt 4000 ] && { echo "could not fill archive below margin" >&2; exit 2; }
done

# Sanity: the listing must exceed the pipe buffer, otherwise the bug can't fire
# and a green result would be meaningless.
listing_bytes=$(find "$MNT" -type f -name '*@*.journal' -printf '%T@ %p\n' | wc -c)
before=$(find "$DST" -name '*@*.journal' | wc -l)
oldest=$(find "$DST" -name '*@*.journal' -printf '%T@ %p\n' | sort -n)  # capture, no head
oldest=${oldest%%$'\n'*}; oldest_name=${oldest##*/}

echo "setup: $before files, listing=${listing_bytes} B (pipe buffer ~65536 B), free < ${MARGIN_MIB} MiB"
fail=0
[ "$listing_bytes" -gt 65536 ] || { echo "FAIL: listing too small to exercise the bug" >&2; fail=1; }

# --- the assertion: the helper must evict, not abort
if "$HELPER"; then rc=0; else rc=$?; fi
after=$(find "$DST" -name '*@*.journal' | wc -l)
free_after=$(free_now)
echo "result: exit=$rc, files ${before} -> ${after}, free_after=${free_after} (margin ${margin_bytes})"

[ "$rc" -eq 0 ]                      || { echo "FAIL: helper exited $rc (eviction aborted, not freeing space)" >&2; fail=1; }
[ "$after" -lt "$before" ]           || { echo "FAIL: no files were evicted" >&2; fail=1; }
[ "${free_after:-0}" -ge "$margin_bytes" ] || { echo "FAIL: free space still below margin after eviction" >&2; fail=1; }
[ ! -e "$DST/$oldest_name" ]         || { echo "FAIL: the oldest journal was not evicted first" >&2; fail=1; }

if [ "$fail" -eq 0 ]; then
    echo "PASS: eviction frees space down to the margin and exits 0"
else
    echo "TEST FAILED"
fi
exit "$fail"
