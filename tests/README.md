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
