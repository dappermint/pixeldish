{
  description = "pixeldish dev tools; the app itself builds with Command Line Tools via just";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # same pins as Whisky so both repos format identically
      swiftformatVersion = "0.58.7";
      # Current SwiftLint release. CI's action bundles its own build, so lint
      # results are close but not guaranteed identical; the SwiftFormat pin is
      # the load-bearing one.
      swiftlintVersion = "0.65.0";

      swiftformat =
        pkgs:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "swiftformat-bin";
          version = swiftformatVersion;
          src = pkgs.fetchurl {
            url = "https://github.com/nicklockwood/SwiftFormat/releases/download/${swiftformatVersion}/swiftformat.zip";
            hash = "sha256-fkP44U4gie64PWlYzhYv+pDJMw8/MJygVGk2FLKxskE=";
          };
          nativeBuildInputs = [ pkgs.unzip ];
          unpackPhase = "unzip $src";
          installPhase = "install -Dm755 swiftformat $out/bin/swiftformat";
        };

      swiftlint =
        pkgs:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "swiftlint-bin";
          version = swiftlintVersion;
          src = pkgs.fetchurl {
            url = "https://github.com/realm/SwiftLint/releases/download/${swiftlintVersion}/portable_swiftlint.zip";
            hash = "sha256-1ssKp6L18e8wb8nje8tU3Jom+syPd4SsDD3T7M9ca6Y=";
          };
          nativeBuildInputs = [ pkgs.unzip ];
          unpackPhase = "unzip $src";
          installPhase = "install -Dm755 swiftlint $out/bin/swiftlint";
        };
    in
    {
      # NoCC: a cc stdenv exports its own SDKROOT/DEVELOPER_DIR, which breaks the justfile's xcrun
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = [
            (swiftformat pkgs)
            (swiftlint pkgs)
            pkgs.just
          ];
          # swiftlint's sourcekitten can't find sourcekitdInProc on a CLT-only machine without this
          shellHook = ''
            export TOOLCHAIN_DIR="$(/usr/bin/xcrun --find swift | sed 's#/usr/bin/swift$##')"
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
