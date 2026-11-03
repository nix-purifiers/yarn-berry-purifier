# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set:
# the scope `pkgs.yarn-berry-purifier`, made with lib.makeScope. The scope
# holds the packages of pkgs/ (`.plugin`, `.yarn` and
# `.yarn-berry-purifier`) and the builder `.buildYarnBerryProject`
# (nix/lib/build-yarn-berry-project.nix), a package for callPackage in that
# scope. `.overrideScope` replaces what everything in the scope shares,
# `.buildYarnBerryProject.override` replaces what the builder takes, and a
# package written for callPackage takes the scope by name. A consumer that
# lists this flake in `projects` holds it as `yarn-berry-purifier/default`,
# which its package sets apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "yarn-berry-purifier";
in
{
  overlay =
    final: prev:
    let
      scoped = packages final prev;
    in
    scoped
    // {
      yarn-berry-purifier = scoped.yarn-berry-purifier.overrideScope (
        self: _: {
          inherit (closure-lib) purifier;
          buildYarnBerryProject = self.callPackage ../../nix/lib/build-yarn-berry-project.nix {
            inherit (closure-lib) purifier;
          };
        }
      );
    };
}
