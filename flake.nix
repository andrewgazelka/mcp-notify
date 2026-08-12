{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
  };

  outputs = { self, nixpkgs, rust-overlay, crane }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      mkPkgs = system: import nixpkgs {
        inherit system;
        overlays = [ rust-overlay.overlays.default ];
      };
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = mkPkgs system;
          rustToolchain = pkgs.rust-bin.stable.latest.default;
          craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

          commonArgs = {
            src = craneLib.cleanCargoSource ./.;
            strictDeps = true;
            buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
              pkgs.libiconv
            ];
          };

          cargoArtifacts = craneLib.buildDepsOnly commonArgs;

          notify = craneLib.buildPackage (commonArgs // {
            inherit cargoArtifacts;
          });
        in
        {
          inherit notify;
          default = notify;
        });

      devShells = forAllSystems (system:
        let
          pkgs = mkPkgs system;
          rustToolchain = pkgs.rust-bin.stable.latest.default.override {
            extensions = [ "rust-src" "rust-analyzer" ];
          };
        in
        {
          default = pkgs.mkShell {
            buildInputs = [
              rustToolchain
              pkgs.cargo-watch
            ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
              pkgs.libiconv
            ];
          };
        });

      overlays.default = final: prev: {
        notify = self.packages.${final.stdenv.hostPlatform.system}.notify;
      };

      # Installs the CLI, config.toml and the launchd agent. It deliberately
      # does NOT build notifyd: the Metal compiler lives in a cryptex mount
      # outside /nix/store, SwiftPM needs the network, the SDK is Xcode-only and
      # the weights are multi-GB. `make install-notifyd` handles that out of
      # band, and the agent is written so that "plist installed, daemon not
      # built yet" is a quiet steady state rather than a respawn loop.
      homeManagerModules.notify = { config, lib, pkgs, ... }: {
        imports = [ ./nix/hm-module.nix ];
        config = lib.mkIf config.programs.notify.enable {
          programs.notify.package = lib.mkDefault
            self.packages.${pkgs.stdenv.hostPlatform.system}.notify;
        };
      };
      homeManagerModules.default = self.homeManagerModules.notify;
    };
}
