# SPDX-License-Identifier: MIT
#
# What the plugin builds for interactive use and for
# `yarn-berry-purifier prefetch`: the directory it serves the project's
# downloads from, the same one a sandboxed build of the project uses. The
# plugin evaluates this file with the absolute paths of the purifier
# lockfile and of the project's yarn.lock, and keeps the result alive with
# a garbage-collector root in the .yarn-berry-purifier directory beside the
# lockfile.
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
  inherit (pkgs) lib;
  lock = import ./lock.nix { inherit lib lockFile yarnLock; };
  # Serving captured downloads also works when both locks live outside the
  # project; package manifests are only needed by its builder.
  read = purifier.checkLock {
    purifier = "yarn-berry-purifier";
    inherit (lock) entries problems;
    outputs = { };
  };
  entries = purifier.entriesFor pkgs.stdenv.hostPlatform.system read;
in
pkgs.callPackage ./served.nix {
  inherit purifier entries;
  inherit (lock) npmLocks externals;
}
