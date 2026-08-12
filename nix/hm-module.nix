# Home-manager module for `notify`.
#
# Scope note: nix installs the Rust CLI, the config file, and the launchd
# agent. It deliberately does NOT build `notifyd` (Metal toolchain lives in a
# cryptex mount, SwiftPM wants the network, SDK is Xcode-only, weights are
# multi-GB). `make install-notifyd` does that out of band. Everything here is
# written so the pre-notifyd state is a perfectly good steady state, not a
# broken half-install.
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.notify;
  inherit (lib) mkEnableOption mkOption mkIf types;

  # The daemon is optional by construction. If the binary is absent this exits
  # 0, and because KeepAlive.SuccessfulExit = false, launchd takes a clean exit
  # as "do not restart" rather than flapping it every 10 seconds forever.
  # `notify` then just uses `say`, which is exactly the old behavior.
  wrapper = pkgs.writeShellScript "notifyd-wrapper" ''
    exec_path="${cfg.daemon.binary}"
    if [ ! -x "$exec_path" ]; then
      echo "notifyd not installed at $exec_path - run 'make install-notifyd'" >&2
      exit 0
    fi
    exec "$exec_path" --serve
  '';

  tomlFormat = pkgs.formats.toml { };
in
{
  options.programs.notify = {
    enable = mkEnableOption "notify, the spoken status line";

    package = mkOption {
      type = types.package;
      description = "The notify CLI package.";
    };

    backend = mkOption {
      type = types.enum [ "auto" "daemon" "say" ];
      default = "auto";
      description = ''
        Where speech goes. "auto" prefers the neural daemon and silently falls
        back to `say` whenever it is not ready, which is the intended setting.
      '';
    };

    engine = mkOption {
      type = types.enum [ "holler" "dots" ];
      default = "holler";
      description = "Neural engine used when the daemon handles the request.";
    };

    voice = mkOption {
      type = types.str;
      default = "oliver";
      description = "Neural voice name.";
    };

    rate = mkOption {
      type = types.float;
      default = 1.5;
      description = ''
        Pitch-preserving speed multiplier, 0.5 to 3.0. This is a time-stretch on
        the rendered audio, not a synthesis parameter, so it does not change
        voice identity.
      '';
    };

    say = {
      wpm = mkOption {
        type = types.int;
        default = 300;
        description = ''
          Words per minute for the `say` fallback. Deliberately decoupled from
          `rate`: the fallback must never get slower than it is today.
        '';
      };
      voice = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Voice for the `say` fallback, or null for the system default.";
      };
    };

    daemon = {
      enable = mkEnableOption "the notifyd launchd agent" // { default = true; };

      label = mkOption {
        type = types.str;
        default = "org.nix-community.home.notifyd";
        description = ''
          launchd label. Must match `notify`'s kickstart target, so it is
          threaded into the generated config rather than hardcoded twice.
        '';
      };

      binary = mkOption {
        type = types.str;
        default = "${config.home.homeDirectory}/.local/libexec/notifyd/notifyd";
        description = "Path where `make install-notifyd` puts the daemon.";
      };
    };

    settings = mkOption {
      type = tomlFormat.type;
      default = { };
      description = "Extra keys merged into config.toml.";
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ cfg.package ];

    xdg.configFile."notify/config.toml".source = tomlFormat.generate "notify-config.toml"
      (lib.recursiveUpdate
        {
          backend = cfg.backend;
          engine = cfg.engine;
          voice = cfg.voice;
          rate = cfg.rate;
          say = { wpm = cfg.say.wpm; } // lib.optionalAttrs (cfg.say.voice != null) {
            voice = cfg.say.voice;
          };
          daemon = { label = cfg.daemon.label; };
        }
        cfg.settings);

    launchd.agents.notifyd = mkIf cfg.daemon.enable {
      enable = true;
      config = {
        Label = cfg.daemon.label;
        ProgramArguments = [ "${wrapper}" ];

        RunAtLoad = true;

        # Restart on a crash, but not on a clean exit. That single distinction
        # is what makes the "binary not installed yet" path quiet instead of a
        # respawn loop.
        KeepAlive.SuccessfulExit = false;

        # CoreAudio needs a GUI session; an agent loaded into Background or
        # LoginWindow has no output device to open.
        LimitLoadToSessionType = "Aqua";

        # Exempt from App Nap and timer coalescing. Without this the resident
        # daemon gets throttled while idle and the first utterance after a
        # quiet period is late, which is precisely the case that must be fast.
        ProcessType = "Interactive";

        StandardOutPath = "${config.home.homeDirectory}/.local/state/notify/notifyd.log";
        StandardErrorPath = "${config.home.homeDirectory}/.local/state/notify/notifyd.log";

        EnvironmentVariables = {
          # launchd agents get a minimal PATH; MLX and HF cache resolution both
          # care about HOME being right.
          HOME = config.home.homeDirectory;
        };
      };
    };

    # launchd refuses to start an agent whose Standard*Path directory does not
    # exist, and it fails silently into the system log rather than anywhere the
    # user will look.
    home.activation.notifyStateDir =
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run mkdir -p "${config.home.homeDirectory}/.local/state/notify"
      '';
  };
}
