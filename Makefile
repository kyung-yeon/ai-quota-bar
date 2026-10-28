SWIFTC = xcrun swiftc
CACHE = /tmp/aiquota-swift-cache
SOURCES = $(wildcard Sources/*.swift) $(wildcard Tests/*.swift) main.swift
TARGET = $(shell uname -m)-apple-macos13.0

.PHONY: build test package check install
build: build/AiQuotaBar

build/AiQuotaBar: $(SOURCES) Makefile
	mkdir -p build
	$(SWIFTC) -target $(TARGET) -module-cache-path $(CACHE) $(SOURCES) -o $@ -framework AppKit -framework Security

test: build
	./build/AiQuotaBar --self-test
	python3 Tests/install_test.py

check: build
	./build/AiQuotaBar --check

package: test
	python3 package.py

install: package
	python3 install.py
