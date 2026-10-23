self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.pixeldish;
  inherit (lib) mkOption types;
  num = types.nullOr types.number;
  opt =
    type: description:
    mkOption {
      type = types.nullOr type;
      default = null;
      inherit description;
    };
  # every field is optional: what is left out takes the app's default. Names go
  # unchecked here and through `Pixeldish --check` at build time, so this list
  # never drifts from the app's
  patternType = types.submodule {
    options = {
      name = opt types.str "label shown in the saved list";
      shape = opt types.str "Drift, Shepard, ... Torus, Kerr, Binary, Cygnus";
      dither = opt types.str "Smooth, Poster, Bayer 2/4/8/16, Noise, R2, Halftone, Lines, Diamond, ASCII, Benday";
      palette = opt types.str "palette name, or Custom together with `custom`";
      custom = opt (types.listOf types.str) "five #rrggbb colours for palette = Custom";
      colors = opt types.int "2 to 5";
      pixelSize = opt types.number "1 to 6";
      warp = opt types.number "0 to 1";
      contrast = opt types.number "0.7 to 1.8";
      grain = opt types.number "0 to 0.12";
      vignette = opt types.number "0 to 1";
      zoom = opt types.number "0.7 to 1.5";
      spread = opt types.number "0 to 0.2";
      speed = opt types.number "0 to 1";
      invert = opt types.bool "invert the field";
      seed = opt types.number "0 to 1000";
      params = mkOption {
        type = types.attrsOf types.number;
        default = { };
        description = "the shape's own knobs, e.g. { spin = 0.9; inclination = 82; } for Kerr";
      };
    };
  };
  patternOrString = types.either types.str patternType;
in
{
  options.services.pixeldish = {
    enable = lib.mkEnableOption "Pixeldish, dithered procedural live wallpapers";
    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "pixeldish.packages.\${system}.default";
    };
    settings = {
      animate = mkOption {
        type = types.nullOr types.bool;
        default = null;
      };
      hyper = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "draw at the display's top refresh rate";
      };
      autoShuffle = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "shuffle every hour";
      };
    };
    pattern = mkOption {
      type = types.nullOr patternOrString;
      default = null;
      example = lib.literalExpression ''
        {
          shape = "Kerr";
          palette = "Dracula Pro";
          dither = "Bayer 8";
          params = { spin = 0.95; inclination = 84; temperature = 1.3; };
        }
      '';
      description = ''
        The pattern on screen. Options as above, a one-line KYAML pattern from
        the app's Copy pattern, or the id of a pattern in `saved`. Applied at
        launch and on every switch that changes it; tweaks in the app last until then.
      '';
    };
    saved = mkOption {
      type = types.listOf patternOrString;
      default = [ ];
      description = "patterns listed under Saved in the app: options or KYAML from Copy pattern";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    environment.etc."pixeldish/config.kyaml".source = pkgs.callPackage ./config.nix { inherit (cfg) package; } {
      inherit (cfg) settings pattern saved;
    };
    # launchd starts it at login, so leave the app's own Launch at login off.
    # Quitting from the menu exits 0 and stays quit; a crash gets restarted
    launchd.user.agents.pixeldish = {
      command = "${cfg.package}/Applications/Pixeldish.app/Contents/MacOS/Pixeldish";
      serviceConfig = {
        RunAtLoad = true;
        KeepAlive.SuccessfulExit = false;
        ProcessType = "Interactive";
        ThrottleInterval = 30;
      };
    };
  };
}
