.PHONY: all build lint clean install-deps install-local

all: build

# Stage the portable core (../../sbin, ../../systemd) together with debian/
# in a temp tree and build there. Output: dist/journald-archive_VERSION_all.deb
build:
	./build.sh

# Lint the most recently built package.
lint:
	lintian --tag-display-limit 0 dist/*.deb

clean:
	rm -rf dist

# Install the build toolchain on a Debian/Ubuntu host.
install-deps:
	sudo apt install --no-install-recommends --yes build-essential debhelper dpkg-dev fakeroot lintian

# Build, then install onto the local host (for testing).
install-local: build
	sudo dpkg --install dist/*.deb || sudo apt --fix-broken install --yes
