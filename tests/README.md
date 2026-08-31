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
