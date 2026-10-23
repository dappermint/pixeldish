{
  description = "pixeldish: dithered procedural live wallpapers for macOS, with a nix-darwin module";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs, ... }:
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

      version = builtins.head (builtins.match ''.*VERSION +:= +"([^"]+)".*'' (builtins.readFile ./justfile));

      # nixpkgs has no AppKit/SwiftUI SDK, so this shells out to the Command Line
      # Tools' swiftc, iconutil and codesign exactly like the justfile. It needs
      # sandbox = false (the darwin default) or relaxed, where __noChroot applies
      pixeldish =
        pkgs:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "pixeldish";
          inherit version;
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./src
              ./saver
              ./tools
              ./Info.plist
              ./justfile
            ];
          };
          __noChroot = true;
          nativeBuildInputs = [ pkgs.just ];
          buildPhase = ''
            export HOME=$TMPDIR PATH=$PATH:/usr/bin
            just icon build
          '';
          doCheck = true;
          checkPhase = "build/Pixeldish.app/Contents/MacOS/Pixeldish --selftest";
          installPhase = ''
            mkdir -p $out/Applications
            cp -R build/Pixeldish.app $out/Applications/
          '';
          meta = {
            description = "Dithered procedural live wallpapers";
            homepage = "https://github.com/dappermint/pixeldish";
            license = pkgs.lib.licenses.mit;
            platforms = pkgs.lib.platforms.darwin;
            mainProgram = "Pixeldish";
          };
        };
    in
    {
      packages = forAllSystems (pkgs: {
        default = pixeldish pkgs;
      });

      darwinModules.default = import ./nix/module.nix self;

      # renders a config the way the module does, which runs the app's --check over it
      checks = forAllSystems (pkgs: {
        config = pkgs.callPackage ./nix/config.nix { package = self.packages.${pkgs.stdenv.hostPlatform.system}.default; } {
          settings.animate = true;
          # the id of the torus below, as Pixeldish --check prints it
          pattern = "683b638e-5c39-5b44-9bd2-ce3d17d5766a";
          saved = [
            ''{shape: "Torus", palette: "Dusk", params: {windings: 9}}''
            {
              shape = "Kerr";
              palette = "Nord";
              params = {
                spin = 0.95;
                inclination = 84;
              };
            }
          ];
        };
      });

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
