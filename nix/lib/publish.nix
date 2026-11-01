# SPDX-License-Identifier: MIT
#
# What `yarn-berry-purifier publish` builds before it publishes: the
# tarball of one package of the project from the project's `release`, as
# package.tgz. The command evaluates this file with the project root, the
# purifier lockfile and the package name.
{
  pkgs,
  # The `purifier` namespace of the shared library.
  purifier,
  # The project root.
  src,
  # The purifier lockfile.
  lockFile ? src + "/yarn-berry-purifier.lock.json",
  # The name of the package to publish.
  package,
}:
let
  project = import ./build-yarn-berry-project.nix { inherit purifier; } {
    inherit pkgs src lockFile;
  };
  file = (builtins.replaceStrings [ "@" "/" ] [ "" "__" ] package) + ".tgz";
in
pkgs.runCommand "yarn-berry-purifier-publish" { } ''
  mkdir -p "$out"
  ln -s ${project.release}/${pkgs.lib.escapeShellArg file} "$out/package.tgz"
''
