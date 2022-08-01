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
    let
      overrideZig = { zig, llvmPackages_14 }: (zig.overrideAttrs (_: {
        version = zig-src.shortRev;
        src = zig-src;
      })).override { llvmPackages = llvmPackages_14; };
    in
    utils.lib.eachDefaultSystem
      (system:
        with import nixpkgs
          {
            overlays = [ self.overlays.default ];
            inherit system;
          }; {
          packages.default = git-brief;

          devShells = rec {
            ci = mkShell {
              packages = [
                libgit2
                (overrideZig { inherit zig llvmPackages_14; })
              ];
            };

            default = mkShell {
              packages = ci.nativeBuildInputs ++ [ zls ];
            };
          };
        }) // {
      overlays.default = (final: prev: {
        git-brief = final.stdenv.mkDerivation {
          pname = "git-brief";
          version = "0.1.0";
          src = ./.;
          buildInputs = [
            final.libgit2
            final.makeBinaryWrapper
            (overrideZig {
              inherit (final) zig llvmPackages_14;
            })
          ];
          buildPhase = ''
            # prevent zig from trying to write to the global cache
            export XDG_CACHE_HOME="$TMP/zig-cache"
            make
          '';
          installPhase = ''
            mkdir -p $out/bin
            cp git $out/bin/git
          '';
          # helps it find git easily
          fixupPhase = ''
            wrapProgram $out/bin/git \
              --prefix PATH : ${final.git}/bin
          '';
        };
      });
    };
}
