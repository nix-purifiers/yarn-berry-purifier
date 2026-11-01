# SPDX-License-Identifier: MIT
{ ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [ inputs.flake-parts.flakeModules.partitions ];

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };

    # The packages are the `default` entry of this flake's package overlay
    # registry (pkg-overlays/): the package set applies it by default, and
    # the flake exports it as `pkgOverlays` and as the plain
    # `overlays.default`.
    nixpkgs = {
      packages.export.enabled = true;
    };
  };

  # `nix run github:nix-purifiers/yarn-berry-purifier#yarn-berry-purifier
  # -- lock` writes the purifier lockfile, and `nix run
  # github:nix-purifiers/yarn-berry-purifier` runs Yarn with the plugin
  # loaded. `nix develop github:nix-purifiers/yarn-berry-purifier` gives a
  # shell with that `yarn`, the `yarn-berry-purifier` command and Node.js.
  perSystem =
    { config, pkgs, ... }:
    {
      packages.default = config.packages.yarn;
      devShells.default = pkgs.mkShell {
        packages = [
          config.packages.yarn
          config.packages.yarn-berry-purifier
          pkgs.nodejs
        ];
      };
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              overlay = self.overlays.default;
              inherit (self.lib) purifier yarn-berry-purifier;
            };
            treefmt.programs.nixfmt.enable = true;
          };
      };
  };

}
