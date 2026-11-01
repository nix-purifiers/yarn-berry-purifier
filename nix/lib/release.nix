# SPDX-License-Identifier: MIT
#
# What `yarn-berry-purifier prefetch` builds for a purifier lockfile whose
# Yarn release comes from repo.yarnpkg.com: that release, fetched as a
# sandboxed build of the project fetches it. The plugin evaluates this file
# with the absolute paths of the purifier lockfile and of the project's
# yarn.lock.
{
  pkgs,
  # The `purifier` namespace of the shared library.
  purifier,
  # The purifier lockfile.
  lockFile,
  # The project's yarn.lock.
  yarnLock,
}:
let
  lock = import ./lock.nix {
    inherit (pkgs) lib;
    inherit lockFile yarnLock;
    inherit (pkgs.stdenv.hostPlatform) system;
  };
in
purifier.fetchEntry { inherit pkgs; } lock.release
