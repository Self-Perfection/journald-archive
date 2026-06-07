PACKAGE := journald-archive
VERSION := $(shell dpkg-parsechangelog --show-field Version 2>/dev/null)
DEB     := ../$(PACKAGE)_$(VERSION)_all.deb

.PHONY: all build clean lint install-deps install-local show

all: build

# Output: ../journald-archive_VERSION_all.deb
build:
	dpkg-buildpackage --unsigned-source --unsigned-changes --build=binary

clean:
	debian/rules clean
	rm -f ../$(PACKAGE)_*.deb ../$(PACKAGE)_*.buildinfo ../$(PACKAGE)_*.changes

# Install build toolchain on Debian/Ubuntu host
install-deps:
	sudo apt install --no-install-recommends --yes build-essential debhelper dpkg-dev fakeroot lintian

# Lint the built package
lint: $(DEB)
	lintian --tag-display-limit 0 $(DEB)

# Install the freshly built package onto the local host (for testing)
install-local: build
	sudo dpkg --install $(DEB) || sudo apt --fix-broken install --yes

show:
	@echo "PACKAGE = $(PACKAGE)"
	@echo "VERSION = $(VERSION)"
	@echo "DEB     = $(DEB)"
