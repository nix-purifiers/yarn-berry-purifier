# SPDX-License-Identifier: MIT
#
# The `yarn-berry-purifier` library namespace: the builder
# `buildYarnBerryProject` (nix/lib/build-yarn-berry-project.nix), which
# takes the package set to build with as its `pkgs` argument. It fetches
# through the `purifier` namespace of the same library.
{ ... }:
{

  overlay = final: prev: {
    yarn-berry-purifier = {
      buildYarnBerryProject = import ../../nix/lib/build-yarn-berry-project.nix {
        inherit (final) purifier;
      };
    };
  };

}
