#!/bin/bash
# Regression test for journald's disposed-of "*.journal~" files.
#
# When journald cannot use a journal file (corrupt, or written with features it
# does not support) it renames it to "<prefix>@<id>-<id>.journal~" and opens a
# fresh one. Those files are sealed and journalctl still reads them, so they are
# ordinary history — but both the archival and the eviction `find` matched only
# '*@*.journal', so they were never moved out of the hot tier (journald's vacuum
# eventually deleted them instead) and, once archived, could never be reclaimed.
# This test asserts both halves: a '.journal~' file is archived like a rotated
# one, and a '.journal~' file in a full archive is evicted like any other.
#
# The two halves must stay together: archiving a shape that eviction cannot
# reclaim would wedge the archive at full.
#
# REQUIREMENTS: run as root on a DISPOSABLE machine. It creates a loopback btrfs
# under a temp dir, *temporarily* swaps /etc/default/journald-archive (restored
# on exit) and drops two throwaway journal-named files into the real
# /var/log/journal/<machine-id>/ (removed on exit; journalctl will call them
# corrupt while they are there). It never touches the real
# /var/log/journal_archive. See the project's build/test VM.
#
# Usage: sudo tests/disposed-journal.sh [path-to-helper]
#   path-to-helper defaults to ../libexec/journald-archive (the working tree).

set -euo pipefail

HELPER="${1:-$(cd "$(dirname "$0")/.." && pwd)/libexec/journald-archive}"
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 2; }
[ -x "$HELPER" ]      || { echo "helper not executable: $HELPER" >&2; exit 2; }

ARCHIVE_MIB=128          # throwaway archive size
MARGIN_MIB=24            # free space the helper must restore
FILL_MIB=8               # per-file size of the incompressible filler

WORK=$(mktemp -d)
IMG="$WORK/archive.btrfs"
MNT="$WORK/mount"
DEFAULTS=/etc/default/journald-archive
BACKUP="$WORK/defaults.bak"
MID=$(cat /etc/machine-id)
SRC="/var/log/journal/$MID"
DST="$MNT/$MID"
created_src=
margin_bytes=$((MARGIN_MIB * 1024 * 1024))

# Distinctive prefix so cleanup can identify our files in the real hot tier.
PFX="journaldarchivetest"
ROTATED="$PFX@0000000000000001-00065a5d27c00b0d.journal"
DISPOSED="$PFX@00065a5d27c00b0d-7875f4c5d8bb1463.journal~"   # journald's shape

cleanup() {
    set +e
    rm -f -- "$SRC/$PFX@"*.journal "$SRC/$PFX@"*.journal~
    mountpoint -q "$MNT" && umount "$MNT"
    if [ -f "$BACKUP" ]; then mv -f "$BACKUP" "$DEFAULTS"; else rm -f "$DEFAULTS"; fi
    [ -n "$created_src" ] && rmdir "$SRC" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

free_now() {
    btrfs filesystem usage -b "$MNT" 2>/dev/null \
        | grep -oPm1 'Free \(estimated\):\s+\K[0-9]+'
}

# --- throwaway archive, same shape as the one the package builds
mkdir -p "$MNT"
fallocate -l "${ARCHIVE_MIB}MiB" "$IMG"
mkfs.btrfs -q --mixed --metadata single --data single "$IMG"
mount -o loop,compress-force=zstd:8 "$IMG" "$MNT"

[ -e "$DEFAULTS" ] && cp -a "$DEFAULTS" "$BACKUP"
mkdir -p "$(dirname "$DEFAULTS")"
cat >"$DEFAULTS" <<CONF
ARCHIVE_MOUNT="$MNT"
ARCHIVE_FILE="$IMG"
FREE_MARGIN_MIB=$MARGIN_MIB
GRACE_MINUTES=0
CONF
[ -d "$SRC" ] || { mkdir -p "$SRC"; created_src=1; }

fail=0

# --- part 1: a '.journal~' file must be archived like a rotated one ----------
# Both are backdated an hour: `find -mmin +0` rounds the age up to whole
# minutes, so a just-created file is "0 minutes old" and would not qualify.
for f in "$ROTATED" "$DISPOSED"; do
    head -c $((1024 * 1024)) /dev/urandom > "$SRC/$f"
    touch -d '-60 minutes' "$SRC/$f"
done

if "$HELPER"; then rc=0; else rc=$?; fi
echo "archival: exit=$rc"
[ "$rc" -eq 0 ]              || { echo "FAIL: helper exited $rc on archival" >&2; fail=1; }
[ -e "$DST/$ROTATED" ]       || { echo "FAIL: rotated journal was not archived" >&2; fail=1; }
[ ! -e "$SRC/$ROTATED" ]     || { echo "FAIL: rotated journal left in the hot tier" >&2; fail=1; }
if [ -e "$DST/$DISPOSED" ] && [ ! -e "$SRC/$DISPOSED" ]; then
    echo "PASS: disposed-of '$DISPOSED' moved to the archive"
else
    echo "FAIL: disposed-of '.journal~' file was not archived" >&2; fail=1
fi

# --- part 2: a '.journal~' file in a full archive must be evictable ----------
# Make the archived '.journal~' the oldest thing in the archive, then fill the
# rest with incompressible fillers until free space drops under the margin. If
# eviction cannot see '.journal~' files it either leaves it untouched (and
# deletes newer files instead) or runs out of candidates before reaching the
# margin — both are caught below.
# Planted directly, not reused from part 1: if part 1 failed to archive it,
# "it is gone afterwards" would be trivially true and this half would pass for
# the wrong reason.
head -c $((4 * 1024 * 1024)) /dev/urandom > "$DST/$DISPOSED"
touch -d '2026-01-01 00:00' "$DST/$DISPOSED"
i=0
while :; do
    seq=$(printf '%016x' $((0x11d2235 + i)))
    f="$DST/filler@$seq-00065a5d27c05d03.journal"
    head -c $((FILL_MIB * 1024 * 1024)) /dev/urandom > "$f"
    touch -d "2026-06-01 +$i minutes" "$f"    # all newer than the '.journal~'
    i=$((i + 1))
    [ "$(free_now)" -lt "$margin_bytes" ] && break
    [ "$i" -gt 64 ] && { echo "could not fill archive below margin" >&2; exit 2; }
done
echo "setup: $i fillers of ${FILL_MIB} MiB, free < ${MARGIN_MIB} MiB"

if "$HELPER"; then rc=0; else rc=$?; fi
free_after=$(free_now)
echo "eviction: exit=$rc, free_after=${free_after} (margin ${margin_bytes})"

[ "$rc" -eq 0 ]                            || { echo "FAIL: helper exited $rc on eviction" >&2; fail=1; }
[ "${free_after:-0}" -ge "$margin_bytes" ] || { echo "FAIL: free space still below margin" >&2; fail=1; }
if [ ! -e "$DST/$DISPOSED" ]; then
    echo "PASS: the oldest archived '.journal~' was evicted"
else
    echo "FAIL: the oldest archived '.journal~' survived eviction" >&2; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "PASS: '*@*.journal~' files are archived and evicted like rotated journals"
else
    echo "TEST FAILED"
fi
exit "$fail"
