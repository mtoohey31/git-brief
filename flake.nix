{
  description = "git-brief";

  inputs = {
    nixpkgs.url = "nixpkgs/nixpkgs-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, utils }: {
    overlays.default = (final: _: {
      git-brief = final.stdenv.mkDerivation {
        pname = "git-brief";
        version = "0.1.1";
        src = ./.;
        buildInputs = [
          final.libgit2
          final.makeBinaryWrapper
          final.zig_0_10
        ];
        XDG_CACHE_HOME = "$TMP/zig-cache";
        makeFlags = [ "PREFIX=$(out)" "ZIG_FLAGS=-Dcpu=baseline" ];
      };
    });
  } // utils.lib.eachDefaultSystem (system: with import nixpkgs
    { overlays = [ self.overlays.default ]; inherit system; }; {
    packages.default = git-brief;

    devShells = rec {
      ci = mkShell {
        packages = [
          libgit2
          zig
        ];
      };

      default = ci.overrideAttrs (oldAttrs: {
        nativeBuildInputs = oldAttrs.nativeBuildInputs ++ [ zls ];
      });
    };
  });
}
