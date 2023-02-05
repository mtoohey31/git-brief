build/debug/bin/git: build.zig $(shell find src -type d -o -name '*.zig')
	zig build $(ZIG_FLAGS) --prefix build/debug

build/release/bin/git: **.zig
	zig build -Drelease-safe $(ZIG_FLAGS) --prefix build/release

PREFIX ?= /usr

.PHONY: install
install:
	zig build -Drelease-safe $(ZIG_FLAGS) --prefix $(PREFIX)

.PHONY: ci
ci: build/release/bin/git fmt-check test

.PHONY: fmt
fmt:
	zig fmt --exclude zig-cache .

.PHONY: fmt-check
fmt-check:
	zig fmt --exclude zig-cache . --check

.PHONY: test
test:
	zig build test $(ZIG_FLAGS)

.PHONY: clean
clean:
	rm -rf build/ zig-cache/ result
