#!/bin/bash
# Build the journald-archive .deb out-of-tree.
#
# dpkg-buildpackage requires debian/ to sit at the root of the build tree,
# alongside the sources it installs. In this repo the portable core
# (libexec/, bin/, systemd/, completions) lives at the repo root while the
# Debian packaging lives under packaging/deb/. We reconcile that by assembling
# a flat build tree in a temporary directory: core + debian/ side by side,
# then build there.
#
# The resulting .deb is moved into ./dist/. Nothing is written back into the
# source tree, so the same core can be wrapped by other packaging methods.
set -euo pipefail

HERE="$(realpath "$(dirname "$0")")"
ROOT="$(realpath "$HERE/../..")"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

SRC="$STAGE/journald-archive"
mkdir -p "$SRC"

# Portable core, shared with every other packaging method.
cp -r "$ROOT/libexec" "$ROOT/bin" "$ROOT/systemd" \
      "$ROOT/bash-completion" "$ROOT/zsh-completion" "$SRC/"
# Debian packaging metadata.
cp -r "$HERE/debian" "$SRC/"

( cd "$SRC" && dpkg-buildpackage --unsigned-source --unsigned-changes --build=binary )

# dpkg-buildpackage drops artifacts in the parent of the source dir ($STAGE);
# only our freshly built .deb lives there.
mkdir -p "$HERE/dist"
mv "$STAGE"/*.deb "$HERE/dist/"

echo "Built: $(ls -1 "$HERE"/dist/*.deb | tail -1)"
