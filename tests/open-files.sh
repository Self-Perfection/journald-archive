#!/bin/bash
# Regression test: eviction must not empty the archive while files are open.
#
# Unlinking a file some process still holds open frees no space until it is
# closed. A long journalctl query over the combined view opens every archived
# file (and mergerfs holds the underlying archive files open for it), so the
# eviction loop — "delete the oldest, re-read free space, repeat until above
# the margin" — never saw free space grow and deleted the entire archive.
#
# Eviction now plans its deletion set up front (just enough of the oldest files
# to cover the free-space deficit) and deletes it in one go. Three cases,
# against a throwaway archive filled past the margin:
#   A. The oldest 3 files are closed, all the rest held open by a process: part
#      of the plan is open, so NOTHING may be deleted — not even the 3 closed
#      ones (eviction stays oldest-first rather than skipping ahead).
#   B. All files held open through a bind mount, i.e. by a different path to
#      the same inodes: fuser matches by inode, so NOTHING may be deleted.
#   C. Nothing open: the helper must free space up to the margin.
#
# REQUIREMENTS: run as root on a DISPOSABLE machine. It creates a loopback btrfs
# under a temp dir and *temporarily* swaps /etc/default/journald-archive
# (restored on exit). It never touches the real /var/log/journal_archive.
#
# Usage: sudo tests/open-files.sh [path-to-helper]
#   path-to-helper defaults to ../libexec/journald-archive (the working tree).

set -euo pipefail

HELPER="${1:-$(cd "$(dirname "$0")/.." && pwd)/libexec/journald-archive}"
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 2; }
[ -x "$HELPER" ]      || { echo "helper not executable: $HELPER" >&2; exit 2; }

ARCHIVE_MIB=256
FILE_KIB=1024
FILL_MARGIN_MIB=16       # fill until free drops below this...
EVICT_MARGIN_MIB=96      # ...then demand this much, a deficit of many files
CLOSED=3                 # case A: this many oldest files are left closed

WORK=$(mktemp -d)
IMG="$WORK/archive.btrfs"
MNT="$WORK/mount"
BIND="$WORK/bind"
DEFAULTS=/etc/default/journald-archive
BACKUP="$WORK/defaults.bak"
MID=$(cat /etc/machine-id)
SRC="/var/log/journal/$MID"
DST="$MNT/$MID"
created_src=
holder=

stop_holder() {
    if [ -n "$holder" ]; then
        kill "$holder" 2>/dev/null || true
        wait "$holder" 2>/dev/null || true   # 143 (killed by TERM) is expected
        holder=
    fi
    return 0
}

# shellcheck disable=SC2317  # only ever invoked via trap
cleanup() {
    set +e
    stop_holder
    mountpoint -q "$BIND" && umount "$BIND"
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

# GRACE_MINUTES is huge so the helper's move step leaves the machine's real hot
# tier alone: this test counts archive files, and journals moved in from
# /var/log/journal (e.g. ones another test just rotated) would skew the count.
write_defaults() {
    cat >"$DEFAULTS" <<EOF
ARCHIVE_MOUNT="$MNT"
ARCHIVE_FILE="$IMG"
FREE_MARGIN_MIB=$1
GRACE_MINUTES=99999999
EOF
}

# Oldest-first list of archived journals, one path per line.
sorted_files() {
    local l
    l=$(find "$1" -type f -name '*@*.journal' -printf '%T@ %p\n' | sort -n)
    [ -n "$l" ] && cut -d' ' -f2- <<<"$l"
    return 0
}

# Start a background process that holds every given file open (like journalctl
# does). Its fds are opened before this returns.
hold_open() {
    local ready="$WORK/holder.ready"
    rm -f "$ready"
    bash -c 'ulimit -n 8192
             for f in "${@:2}"; do exec {fd}<"$f"; done
             : >"$1"
             exec sleep 3600' _ "$ready" "$@" &
    holder=$!
    for _ in $(seq 100); do [ -e "$ready" ] && return 0; sleep 0.1; done
    echo "holder did not start" >&2; exit 2
}

count() { find "$DST" -name '*@*.journal' | wc -l; }

# --- throwaway archive, filled past the margin
mkdir -p "$MNT" "$BIND"
fallocate -l "${ARCHIVE_MIB}MiB" "$IMG"
mkfs.btrfs -q --mixed --metadata single --data single "$IMG"
mount -o loop,compress-force=zstd:8 "$IMG" "$MNT"
[ -e "$DEFAULTS" ] && cp -a "$DEFAULTS" "$BACKUP"
mkdir -p "$(dirname "$DEFAULTS")"
[ -d "$SRC" ] || { mkdir -p "$SRC"; created_src=1; }

mkdir -p "$DST"
i=0
while :; do
    seq=$(printf '%016x' $((0x11d2235 + i)))
    tail=$(printf '%016x' $((0x64a58ec789800 + i * 1000)))
    f="$DST/system@5b56bccf4e4b43f3930fcf617d86485c-$seq-$tail.journal"
    head -c $((FILE_KIB * 1024)) /dev/urandom > "$f"
    touch -d "2026-01-01 +$i minutes" "$f"
    i=$((i + 1))
    [ "$(free_now)" -lt $((FILL_MARGIN_MIB * 1048576)) ] && break
    [ "$i" -gt 4000 ] && { echo "could not fill archive" >&2; exit 2; }
done
write_defaults "$EVICT_MARGIN_MIB"
sync; btrfs filesystem sync "$MNT" >/dev/null
fail=0

# --- case A: oldest $CLOSED closed, the rest held open by their real path
mapfile -t files < <(sorted_files "$DST")
before=${#files[@]}
hold_open "${files[@]:$CLOSED}"
echo "A: $before files, oldest $CLOSED closed, rest held open; free=$(free_now)"
if "$HELPER" 2>"$WORK/a.err"; then rc=0; else rc=$?; fi
after=$(count)
echo "A: exit=$rc, files $before -> $after"; sed 's/^/A: stderr: /' "$WORK/a.err"
[ "$rc" -eq 0 ] || { echo "FAIL A: helper exited $rc" >&2; fail=1; }
[ "$after" -eq "$before" ] \
    || { echo "FAIL A: $((before - after)) files deleted while part of the plan was open" >&2; fail=1; }
grep -q 'eviction postponed' "$WORK/a.err" || { echo "FAIL A: no 'postponed' warning" >&2; fail=1; }
stop_holder

# --- case B: everything held open through a bind mount (another path, same inodes)
mount --bind "$MNT" "$BIND"
mapfile -t files < <(sorted_files "$BIND/$MID")
before=${#files[@]}
hold_open "${files[@]}"
echo "B: $before files, all held open via bind mount; free=$(free_now)"
if "$HELPER" 2>"$WORK/b.err"; then rc=0; else rc=$?; fi
after=$(count)
echo "B: exit=$rc, files $before -> $after"; sed 's/^/B: stderr: /' "$WORK/b.err"
[ "$rc" -eq 0 ] || { echo "FAIL B: helper exited $rc" >&2; fail=1; }
[ "$after" -eq "$before" ] \
    || { echo "FAIL B: $((before - after)) files deleted while held open via a bind mount" >&2; fail=1; }
grep -q 'eviction postponed' "$WORK/b.err" || { echo "FAIL B: no 'postponed' warning" >&2; fail=1; }
stop_holder
umount "$BIND"

# --- case C: nothing open; demand more than the fill left (the helper caps the
# margin at half the archive).
C_MARGIN_MIB=120
write_defaults "$C_MARGIN_MIB"
btrfs filesystem sync "$MNT" >/dev/null
before=$(count)
echo "C: $before files, nothing open; free=$(free_now)"
if "$HELPER" 2>"$WORK/c.err"; then rc=0; else rc=$?; fi
after=$(count); free_after=$(free_now)
echo "C: exit=$rc, files $before -> $after, free_after=$free_after (margin $((C_MARGIN_MIB * 1048576)))"
sed 's/^/C: stderr: /' "$WORK/c.err"
[ "$rc" -eq 0 ] || { echo "FAIL C: helper exited $rc" >&2; fail=1; }
[ "$after" -lt "$before" ] || { echo "FAIL C: nothing evicted" >&2; fail=1; }
[ "${free_after:-0}" -ge $((C_MARGIN_MIB * 1048576)) ] \
    || { echo "FAIL C: free space still below margin" >&2; fail=1; }

if [ "$fail" -eq 0 ]; then
    echo "PASS: eviction deletes nothing while due files are open, and frees the margin otherwise"
else
    echo "TEST FAILED"
fi
exit "$fail"
