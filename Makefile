# Everything here runs in a plain Linux container: no KOReader, no Kindle.

DIST ?= dist
CHANNEL ?= stable
BASE_URL ?= https://npwork.github.io/koreader-ai-plugin

.PHONY: help test lint check check-all package repo verify kpm test-distribution clean

help:
	@echo "make test              busted: units, the KOReader layer, and live HTTP"
	@echo "make lint              luacheck over the plugin and the specs"
	@echo "make verify            build the .kpkg, install/upgrade/uninstall it in a temp tree"
	@echo "make check             lint + test + verify"
	@echo ""
	@echo "make kpm               build the real KPM against system libraries"
	@echo "make test-distribution drive that KPM through install, upgrade and uninstall over HTTP"
	@echo "make check-all         check + test-distribution"
	@echo ""
	@echo "make package           build $(DIST)/<id>_<version>_kindleany.kpkg"
	@echo "make repo              fold built packages into $(DIST)/repo/$(CHANNEL)/"
	@echo "make clean             remove $(DIST)"

test:
	busted

lint:
	luacheck plugin spec scripts

verify:
	./scripts/verify-package.sh

check: lint test verify

kpm:
	./scripts/kpm-host-build.sh

test-distribution: .kpm/build/cli/kpm
	./scripts/test-distribution.sh

.kpm/build/cli/kpm:
	./scripts/kpm-host-build.sh

check-all: check test-distribution

package:
	python3 scripts/kpmrepo.py package --output $(DIST)

repo: package
	python3 scripts/kpmrepo.py repo --channel $(CHANNEL) --base-url $(BASE_URL)

clean:
	rm -rf $(DIST)
