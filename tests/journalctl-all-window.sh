#!/bin/bash
# Tests for journalctl-all's --since/--until file pruning.
#
# journalctl-all hands journalctl a temporary directory of symlinks to only the
# journal files whose [head realtime, mtime] span can overlap the query window,
# and falls back to the full directory whenever pruning might change the result.
#
# Part 1 (logic): a fake journal tree with crafted names/mtimes and a stub
#   `journalctl` on PATH that records which directory it was given and which
#   files it saw. Checks the selected set for several windows, every fallback
#   case, that the temp directory is removed, that the exit code is passed
#   through, and that Ctrl-C (SIGINT to the process group) still cleans up.
# Part 2 (end to end): makes real rotated journals with marker messages, then
#   asserts that `journalctl-all` prints exactly what `journalctl -D` prints for
#   several windows while opening fewer files.
#
# REQUIREMENTS: root on a DISPOSABLE machine (part 2 rotates the real journal
# and logs marker messages to it).
#
# Usage: sudo tests/journalctl-all-window.sh [path-to-journalctl-all]

set -euo pipefail

WRAPPER="${1:-$(cd "$(dirname "$0")/.." && pwd)/bin/journalctl-all}"
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 2; }
[ -x "$WRAPPER" ]     || { echo "not executable: $WRAPPER" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

# ---------------------------------------------------------------- part 1
TREE="$WORK/combined"
MID=0123456789abcdef0123456789abcdef
SEQID=5b56bccf4e4b43f3930fcf617d86485c
mkdir -p "$TREE/$MID"
B=1700000000

# mk <prefix> <head offset s> <mtime offset s> -> rotated journal
mk() {
    local f
    f=$(printf '%s/%s/%s@%s-%016x-%016x.journal' "$TREE" "$MID" "$1" "$SEQID" "$2" $(( (B + $2) * 1000000 )))
    : >"$f"; touch -d "@$((B + $3))" "$f"
}
mk system 1000 2000            # F1  [1000,2000]
mk system 2000 3000            # F2  [2000,3000]
mk system 3000 4000            # F3  [3000,4000]
mk user-1000 2000 3000         # U2  [2000,3000]
: >"$TREE/$MID/system.journal"                    # active: always
f="$TREE/$MID/system@00065a5d27c00b0d-7875f4c5d8bb1463.journal~"
: >"$f"; touch -d "@$((B + 1500))" "$f"           # disposed: always
: >"$TREE/remote.journal"                         # top level: journalctl -D reads it
mkdir -p "$TREE/$MID/deeper"                      # below <machine-id>/: journalctl
mk2=$(printf '%s/%s/deeper/system@%s-%016x-%016x.journal' "$TREE" "$MID" "$SEQID" 1 $(( (B + 3500) * 1000000 )))
: >"$mk2"; touch -d "@$((B + 4000))" "$mk2"       # -D ignores it, so must we

STUB="$WORK/stub"
mkdir -p "$STUB"
cat >"$STUB/journalctl" <<'EOF'
#!/bin/sh
# Records the --directory it got and the journal names visible through it.
for a; do case $a in --directory=*) d=${a#--directory=} ;; esac; done
echo "$d" >"$STUB_OUT.dir"
find "$d" -mindepth 1 \( -type l -o -type f \) -printf '%P\n' | sort >"$STUB_OUT.files"
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
exit "${STUB_RC:-0}"
EOF
chmod +x "$STUB/journalctl"

run() {   # run <args...>; leaves $WORK/out.{dir,files}, sets $rc
    rc=0
    STUB_OUT="$WORK/out" PATH="$STUB:$PATH" JOURNALCTL_ALL_DIR="$TREE" \
        "$WRAPPER" "$@" 2>/dev/null || rc=$?
}
names() {  # short labels of what the stub saw
    local l=() n
    while IFS= read -r n; do
        case $n in
            remote.journal)     l+=(top); continue ;;
            */deeper/*)         l+=(DEEP); continue ;;
            */*) n=${n##*/} ;;
        esac
        case $n in
            system.journal)     l+=(active) ;;
            *.journal~)         l+=(disposed) ;;
            user-1000@*)        l+=(U2) ;;
            system@*-00000000000003e8-*) l+=(F1) ;;
            system@*-00000000000007d0-*) l+=(F2) ;;
            system@*-0000000000000bb8-*) l+=(F3) ;;
            *) l+=("?$n") ;;
        esac
    done <"$WORK/out.files"
    printf '%s\n' "${l[@]}" | sort | tr '\n' ' ' | sed 's/ $//'
}
expect_pruned() {  # expect_pruned "<labels>" <args...>
    local want=$1; shift
    run "$@"
    local d; d=$(cat "$WORK/out.dir")
    if [ "$d" = "$TREE" ]; then bad "pruning expected, got full dir for: $*"; return; fi
    local got; got=$(names)
    [ "$got" = "$want" ] || bad "for '$*': want [$want], got [$got]"
    [ ! -e "$d" ] || bad "temp dir $d left behind for: $*"
}
expect_full() {
    run "$@"
    [ "$(cat "$WORK/out.dir")" = "$TREE" ] || bad "full dir expected for: $*"
}

S() { echo "@$((B + $1))"; }

# windows
expect_pruned "F2 F3 U2 active disposed top"    --since "$(S 2500)"
expect_pruned "F2 F3 U2 active disposed top"    --since="$(S 2500)"
expect_pruned "F2 F3 U2 active disposed top"    -S "$(S 2500)"
expect_pruned "F2 F3 U2 active disposed top"    "-S$(S 2500)"
expect_pruned "F2 F3 U2 active disposed top"    -rS "$(S 2500)"     # bundled
expect_pruned "F1 F2 U2 active disposed top"   --since "$(S 2000)" --until "$(S 2500)" # boundary: mtime == since
expect_pruned "F1 active disposed top"          --until "$(S 1500)"
expect_pruned "F2 U2 active disposed top"       --since "$(S 2100)" --until "$(S 2900)"
expect_pruned "F2 U2 active disposed top"       -S "$(S 2100)" -U "$(S 2900)" --system -u foo.service -n 5 -o cat --no-pager
expect_pruned "F2 U2 active disposed top"       --grep -S --since "$(S 2100)" --until "$(S 2900)"  # -S is grep's value
expect_pruned "F2 U2 active disposed top"       --since "$(S 2100)" --until "$(S 2900)" -- -f -b  # matches after --
expect_pruned "F2 U2 active disposed top"       --since "$(S 2100)" --until "$(S 2900)" --boot=0123456789abcdef0123456789abcdef
expect_pruned "F2 U2 active disposed top"       --since "$(S 2100)" --until "$(S 2900)" _PID=1
expect_pruned "F2 U2 active disposed top"       --utc --since "$(S 2100)" --until "$(S 2900)"  # @epoch: same in any TZ
# fallbacks
expect_full --since "$(S 0)"                          # window keeps every file:
expect_full --until "$(S 9999)"                       # a mirror would buy nothing
expect_full
expect_full -u foo.service
expect_full --since garbage-time
expect_full --since "$(S 2500)" --until garbage-time  # one bad bound of two
expect_full -f --since "$(S 2500)"
expect_full --follow --since "$(S 2500)"
expect_full -fS "$(S 2500)"
expect_full -b --since "$(S 2500)"
expect_full -b -1 --since "$(S 2500)"
expect_full --boot --since "$(S 2500)"
expect_full --boot=-1 --since "$(S 2500)"
expect_full -k --since "$(S 2500)"
expect_full -D /x --since "$(S 2500)"
expect_full --file=/x --since "$(S 2500)"
expect_full -M foo --since "$(S 2500)"
expect_full --root=/ --since "$(S 2500)"
expect_full --list-boots --since "$(S 2500)"
expect_full --disk-usage --since "$(S 2500)"
expect_full -F _PID --since "$(S 2500)"
expect_full --since "$(S 2500)" --frobnicate
expect_full --since "$(S 2500)" -Z
expect_full --since                                   # dangling: journalctl complains

# exit code is passed through, temp dir still removed
STUB_RC=3 run --since "$(S 2500)"
[ "$rc" -eq 3 ] || bad "exit code not passed through (got $rc)"
[ ! -e "$(cat "$WORK/out.dir")" ] || bad "temp dir left after non-zero exit"

# Ctrl-C: SIGINT to the whole process group, as a terminal sends it
rm -f "$WORK/out.dir"
set -m   # background jobs get their own process group and default SIGINT
STUB_SLEEP=5 STUB_OUT="$WORK/out" PATH="$STUB:$PATH" JOURNALCTL_ALL_DIR="$TREE" \
    "$WRAPPER" --since "$(S 2500)" 2>/dev/null &
pid=$!
set +m
for _ in $(seq 50); do [ -s "$WORK/out.dir" ] && [ "$(cat "$WORK/out.dir")" != "$TREE" ] && break; sleep 0.1; done
tmpd=$(cat "$WORK/out.dir")
kill -INT -- "-$pid"
rc=0; wait "$pid" || rc=$?
[ "$rc" -eq 130 ] || bad "Ctrl-C: expected exit 130, got $rc"
[ ! -e "$tmpd" ] || bad "Ctrl-C: temp dir $tmpd left behind"

echo "part 1 (logic) done"

# ---------------------------------------------------------------- part 2
REAL=/var/log/journal
TAG="jaw-test-$$"
ts=()
for i in 1 2 3 4; do
    logger -t "$TAG" "marker $i"
    journalctl --sync
    sleep 1.1
    journalctl --rotate
    ts+=("@$(date +%s.%N)")
    sleep 1.1
done
logger -t "$TAG" "marker 5"; journalctl --sync

cmp_case() {
    local a b
    a=$(journalctl -D "$REAL" -t "$TAG" -o short-unix --no-pager -q "$@")
    b=$(JOURNALCTL_ALL_DIR="$REAL" JOURNALCTL_ALL_VERBOSE=1 \
        "$WRAPPER" -t "$TAG" -o short-unix --no-pager -q "$@" 2>"$WORK/v.err")
    local v; v=$(grep -o '[0-9]* of [0-9]* files' "$WORK/v.err" || true)
    echo "e2e $*: $(grep -c . <<<"$a") entries, pruned to: ${v:-NOT PRUNED}"
    [ "$a" = "$b" ] || { bad "output differs for: $*"; diff <(echo "$a") <(echo "$b") | head >&2; }
    [ -n "$v" ] || bad "not pruned: $*"
    local n m; n=${v%% of*}; m=${v#* of }; m=${m%% *}
    [ "$n" -lt "$m" ] || bad "nothing pruned away for: $*"
}
cmp_case --since "${ts[2]}"
cmp_case --until "${ts[1]}"
cmp_case --since "${ts[0]}" --until "${ts[2]}"
cmp_case --system --since "${ts[1]}" --until "${ts[2]}"
cmp_case -r -S "${ts[1]}"

if [ "$fail" -eq 0 ]; then echo "PASS: journalctl-all prunes by time window, falls back when unsure"; else echo "TEST FAILED"; fi
exit "$fail"
