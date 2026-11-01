# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.yarn-berry-purifier`: the plugin, the `yarn` wrapper that loads it,
# and the `yarn-berry-purifier` command. A consumer that lists this flake
# in `projects` holds it as `yarn-berry-purifier/default`, which its
# package sets apply by default.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "yarn-berry-purifier";
}
