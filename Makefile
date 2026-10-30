SWIFTC = xcrun swiftc
CACHE = /tmp/aiquota-swift-cache
SOURCES = $(wildcard Sources/*.swift) $(wildcard Tests/*.swift) main.swift
ARCH = $(shell uname -m)

.PHONY: build test package check install
build: build/AiQuotaBar

build/AiQuotaBar: build/$(ARCH)/AiQuotaBar
	cp $< $@

build/%/AiQuotaBar: $(SOURCES) Makefile
	mkdir -p $(dir $@)
	$(SWIFTC) -target $*-apple-macos13.0 -module-cache-path $(CACHE)/$* $(SOURCES) -o $@ -framework AppKit -framework Security

build/universal/AiQuotaBar: build/arm64/AiQuotaBar build/x86_64/AiQuotaBar
	mkdir -p $(dir $@)
	xcrun lipo -create $^ -output $@

test: build
	./build/AiQuotaBar --self-test
	python3 -m unittest discover -s Tests -p '*_test.py'

check: build
	./build/AiQuotaBar --check

package: test
	python3 package.py

install: package
	python3 install.py
