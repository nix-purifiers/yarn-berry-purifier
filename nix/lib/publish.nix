# SPDX-License-Identifier: MIT
#
# What `yarn-berry-purifier publish` builds before it publishes: the
# tarball of one package of the project from the project's `release`, as
# package.tgz. The command evaluates this file with a package set that has
# the yarn-berry-purifier overlay, the project root, the purifier lockfile
# and the package name.
{
  pkgs,
  # The project root.
  src,
  # Yarn's lockfile.
  yarnLock ? src + "/yarn.lock",
  # The purifier lockfile.
  lockFile ? src + "/yarn-berry-purifier.lock.json",
  # The name of the package to publish.
  package,
}:
let
  project = pkgs.yarn-berry-purifier.buildYarnBerryProject { inherit src yarnLock lockFile; };
  file = (builtins.replaceStrings [ "@" "/" ] [ "" "__" ] package) + ".tgz";
in
pkgs.runCommand "yarn-berry-purifier-publish" { } ''
  mkdir -p "$out"
  ln -s ${project.release}/${pkgs.lib.escapeShellArg file} "$out/package.tgz"
''
