.PHONY: all build lint shellcheck clean install-deps install-local

ROOT := $(abspath ../..)

all: build

# Stage the portable core (../../sbin, ../../systemd) together with debian/
# in a temp tree and build there. Output: dist/journald-archive_VERSION_all.deb
build:
	./build.sh

# Lint the most recently built package.
lint:
	lintian --tag-display-limit 0 dist/*.deb

# Static analysis of every shell script in the repo (core, packaging, tests).
# Scripts are found by shebang, so a new one is covered without touching this
# list; untracked-but-not-ignored files are included so it also works before
# `git add`. The bash completion has no shebang (it is sourced) and is checked
# explicitly as bash; the zsh completion is skipped (shellcheck has no zsh).
shellcheck:
	cd $(ROOT) && git ls-files -co --exclude-standard | while IFS= read -r f; do \
	    case $$(head -n1 -- "$$f" 2>/dev/null) in \
	        '#!/bin/sh'*|'#!/bin/bash'*|'#!/usr/bin/env sh'*|'#!/usr/bin/env bash'*) \
	            printf '%s\n' "$$f" ;; \
	    esac; \
	done | xargs -r -d '\n' shellcheck --severity=warning --
	cd $(ROOT) && shellcheck --severity=warning --shell=bash bash-completion/journalctl-all

clean:
	rm -rf dist

# Install the build toolchain on a Debian/Ubuntu host.
install-deps:
	sudo apt install --no-install-recommends --yes build-essential debhelper dpkg-dev fakeroot lintian shellcheck

# Build, then install onto the local host (for testing).
install-local: build
	sudo dpkg --install dist/*.deb || sudo apt --fix-broken install --yes
