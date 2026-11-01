# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.yarn-berry-purifier` (`.plugin`, `.yarn` and `.yarn-berry-purifier`),
# and the builder `pkgs.buildYarnBerryProject`
# (nix/lib/build-yarn-berry-project.nix) beside them, where nixpkgs keeps
# its own builders, so a package written for callPackage takes it by name.
# A consumer that lists this flake in `projects` holds it as
# `yarn-berry-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "yarn-berry-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildYarnBerryProject = final.callPackage ../../nix/lib/build-yarn-berry-project.nix {
        inherit (closure-lib) purifier;
      };
    };
}
