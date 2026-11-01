# SPDX-License-Identifier: MIT
#
# What the plugin builds for interactive use and for
# `yarn-berry-purifier prefetch`: the directory it serves the project's
# downloads from, the same one a sandboxed build of the project uses. The
# plugin evaluates this file with the absolute paths of the purifier
# lockfile and of the project's yarn.lock, and keeps the result alive with
# a garbage-collector root under .yarn/purifier.
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
pkgs.callPackage ./served.nix {
  inherit purifier;
  inherit (lock)
    downloads
    npmLocks
    externals
    repositories
    ;
}
