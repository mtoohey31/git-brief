{
  description = "git-brief";

  inputs = {
    nixpkgs.url = "nixpkgs/nixpkgs-unstable";
    utils.url = "github:numtide/flake-utils";
    zig-src = {
      url = "github:ziglang/zig";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, utils, zig-src }:
    utils.lib.eachDefaultSystem (system:
      with import nixpkgs { inherit system; }; {
        devShells.default = mkShell {
          packages = [
            libgit2
            ((zig.overrideAttrs (_: {
              version = zig-src.shortRev;
              src = zig-src;
            })).override { llvmPackages = llvmPackages_14; })
            zls
          ];
        };
      });
}
