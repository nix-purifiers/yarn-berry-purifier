# SPDX-License-Identifier: MIT
#
# What `yarn purifier publish` builds before it publishes: the tarball of
# one package of the project, as the sandboxed build of the project packs
# it. The command evaluates this file with the project root and the
# package name.
{
  pkgs,
  # The project root.
  src,
  # The name of the package to publish.
  package,
}:
let
  project = pkgs.callPackage ./build-yarn-berry-project.nix { } { inherit src; };
in
project.packages.${package}.tarball
