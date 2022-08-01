.PHONY: default ci fmt fmt-check test

default: git

ci: default fmt-check test

# debug build
zig-out/bin/git-brief: **.zig
	zig build

# release build
git: **.zig
	zig build -Drelease-safe && mv zig-out/bin/git-brief $@

fmt:
	zig fmt --exclude zig-cache .

fmt-check:
	zig fmt --exclude zig-cache . --check

test:
	zig build test

clean:
	rm -rf git zig-cache zig-out
