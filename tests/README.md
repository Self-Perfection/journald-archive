# Tests

Functional tests for journald-archive. They exercise behaviour that only shows
up against a real btrfs archive, so they need root and a loop device and are
meant to run on a **disposable** machine (the project's build/test VM), not your
workstation.

Each test runs the working-tree helper directly (no install needed) and cleans
up after itself, including restoring `/etc/default/journald-archive`.

## `eviction.sh`

Regression test for archive eviction. Fills a throwaway btrfs archive past the
free-space margin with enough incompressible, journal-named files that the file
listing outgrows the ~64 KiB pipe buffer, then runs the helper and asserts it
frees space and exits 0.

This guards the 0.3.4 bug: eviction selected the oldest file with
`find ... | sort -n | head -1`, and under `set -o pipefail` the early-closing
`head` made `sort` die on SIGPIPE (141), aborting the helper before it deleted
anything — so a full archive silently never self-evicted. A smoke test on an
empty archive does not catch this, because eviction only runs when the archive
is actually full.

```bash
sudo tests/eviction.sh                       # tests ../libexec/journald-archive
sudo tests/eviction.sh /path/to/helper       # or a specific helper
```

Exit code 0 = PASS. Takes ~30 s (writes a few hundred MiB through zstd).

## `disposed-journal.sh`

Regression test for journald's `*.journal~` files: when journald cannot use a
journal file it renames it to `<prefix>@<id>-<id>.journal~` and opens a fresh
one. Those files are sealed and `journalctl` still reads them, but the helper's
`find` patterns matched only `*@*.journal`, so they were never archived — and
had one reached the archive, eviction could not have reclaimed it either.

The test asserts both halves against a throwaway archive: a `.journal~` file in
the hot tier is moved into the archive, and the oldest archived `.journal~` file
is evicted when the archive fills. It also drops two throwaway journal-named
files into the real `/var/log/journal/<machine-id>/` (removed on exit), so it is
even more firmly VM-only than `eviction.sh`.

```bash
sudo tests/disposed-journal.sh               # tests ../libexec/journald-archive
sudo tests/disposed-journal.sh /path/to/helper
```

Exit code 0 = PASS. Takes ~20 s.

## `open-files.sh`

Regression test for eviction emptying the whole archive while its files are
open. Unlinking an open file frees no space until it is closed; a long
`journalctl-all` query opens every archived file (mergerfs holds the underlying
archive files open for it), so the old loop — delete the oldest, re-read free
space, repeat — never saw free space grow and deleted everything. Eviction now
plans its deletion set up front and deletes it in one go.

Three cases against a throwaway archive filled past the margin:

- **A.** The oldest 3 files are closed, the rest held open: part of the plan is
  open, so nothing at all may be deleted (eviction stays oldest-first).
- **B.** All files held open through a bind mount (another path to the same
  inodes): `fuser` matches by inode, so again nothing may be deleted.
- **C.** Nothing open: free space must be restored to the margin.

```bash
sudo tests/open-files.sh                     # tests ../libexec/journald-archive
sudo tests/open-files.sh /path/to/helper
```

Exit code 0 = PASS. Takes ~5 s. Against the 0.3.7 helper case A goes from 247
files to 0.

Eviction has two sizing paths — `compsize` if installed, otherwise the
archive's average compression ratio — so run the eviction tests both with and
without `btrfs-compsize` installed.

## `journalctl-all-window.sh`

Tests `journalctl-all`'s `--since`/`--until` pruning (a temporary directory of
symlinks to only the files whose `[head, mtime]` span overlaps the window).

- **Logic:** a fake journal tree with crafted names and mtimes and a stub
  `journalctl` on `PATH` that records the directory it was given. Checks the
  selected set for several windows and argument spellings (`-S X`, `-SX`,
  `--since=X`, bundled `-rS X`), every fallback to the full directory (`-f`,
  `-b`, `-k`, `-D`, `--file`, `-M`, `--list-boots`, unknown options, bad
  times, ...), that the temp directory is removed, the exit code is passed
  through, and that Ctrl-C still cleans up.
- **End to end:** creates real rotated journals with marker messages and
  asserts `journalctl-all` prints exactly what `journalctl -D` prints for
  several windows while opening fewer files.

```bash
sudo tests/journalctl-all-window.sh          # tests ../bin/journalctl-all
sudo tests/journalctl-all-window.sh /path/to/journalctl-all
```

Exit code 0 = PASS. Takes ~10 s. It rotates the real journal and logs marker
messages to it, so run it on the disposable VM only.
