# Everything here runs in a plain Linux container: no KOReader, no Kindle.

LUA ?= lua5.1
DIST ?= dist
CHANNEL ?= stable
BASE_URL ?= https://repo.example/kpm

.PHONY: help test lint check package repo verify clean

help:
	@echo "make test      run the busted suite"
	@echo "make lint      run luacheck over the plugin and the specs"
	@echo "make check     lint + test + package verification"
	@echo "make package   build $(DIST)/<id>_<version>_kindleany.kpkg"
	@echo "make repo      fold built packages into $(DIST)/repo/$(CHANNEL)/"
	@echo "make verify    install, upgrade and uninstall the package in a temp tree"
	@echo "make clean     remove $(DIST)"

test:
	busted

lint:
	luacheck plugin spec scripts

check: lint test verify

package:
	python3 scripts/kpmrepo.py package --output $(DIST)

repo: package
	python3 scripts/kpmrepo.py repo --channel $(CHANNEL) --base-url $(BASE_URL)

verify:
	./scripts/verify-package.sh

clean:
	rm -rf $(DIST)
