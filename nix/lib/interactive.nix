# SPDX-License-Identifier: MIT
#
# What the plugin builds for interactive use: the directory it serves the
# project's downloads from, the same one a sandboxed build of the project
# uses. The plugin evaluates this file with the absolute path of the
# purifier lockfile and keeps the result alive with a GC root under
# .yarn/purifier.
{
  pkgs,
  lockFile,
}:
let
  lock = import ./lock.nix {
    inherit (pkgs) lib;
    inherit lockFile;
    yarnLockFile = dirOf lockFile + "/yarn.lock";
    inherit (pkgs.stdenv.hostPlatform) system;
  };
in
pkgs.callPackage ./served.nix {
  inherit (lock)
    downloads
    texts
    npmLocks
    externals
    repositories
    ;
}
