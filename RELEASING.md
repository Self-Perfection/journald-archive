# Releasing

Cutting a new journald-archive release. Do these in order; the last two are
enforced by the GitHub Actions release workflow, the rest are on you.

## 1. Functional tests (on the disposable build/test VM)

Build/test happens on a throwaway VM with root, systemd, loop devices and btrfs
(GitHub Actions only does the clean-room release build — it does **not** run
these). Copy the working tree up and run:

```bash
make -C packaging/deb build         # builds the .deb
sudo tests/eviction.sh              # regression test: archive eviction must
                                    # free space and exit 0 (see tests/README.md)
```

`tests/eviction.sh` exists because eviction was once broken for months while
"service exited 0" smoke tests stayed green — they ran on an empty archive and
never triggered eviction. **A green build is not enough; run the tests against a
full archive.** Add a test here whenever a fix touches a path that only runs
under real load.

Then install the `.deb` on the VM and sanity-check the live units
(`systemctl status`, `journalctl-all`, run `journald-archive.service` once).

## 2. Finalize the changelog

In `packaging/deb/debian/changelog`, the top entry must name a real
distribution (`unstable`), **not** `UNRELEASED`, and its version must equal the
tag you are about to push. Update the date (`date -R`). A stale `UNRELEASED`
both ships in the `.deb` and fails the release workflow's gate.

Pick `urgency` to match the release, don't just copy the previous entry — it is
the changelog's one-word statement of how much a user should care:

- `urgency=low` — cleanup, docs, optimization, refactors: nothing that changes
  behaviour for a working install (e.g. the 0.3.2 shebang and 0.3.3 space
  changes).
- `urgency=medium` — bug fixes, especially anything that affected a core or
  user-visible path (e.g. the 0.3.4 eviction fix). "Worth upgrading for."
- `urgency=high` — data loss, corruption, or security: staying on the old
  version risks losing logs or worse.

(In a Debian archive `urgency` also sets the unstable→testing migration delay;
here it is effectively just that human signal, but keep it honest anyway.)

## 3. Commit, tag, push

```bash
git commit -am "…(<version>)"
git tag v<version>          # must match the changelog version exactly
git push origin main
git push origin v<version>  # the tag push triggers the release build
```

The release workflow (`.github/workflows/release.yml`) then, from the tagged
commit only: verifies the changelog version/distribution against the tag, builds
the `.deb` clean-room, lints it, and publishes the GitHub Release with the `.deb`
attached. Building from the tag (not a working tree) guarantees the embedded
changelog matches what is published.
