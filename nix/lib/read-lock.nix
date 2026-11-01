# SPDX-License-Identifier: MIT
#
# `readLock`: the lock in memory of the purifier contract, read from a
# project's yarn.lock and its purifier lockfile:
#
#   purifier  "yarn-berry-purifier"
#   entries   the download entries of the purifier library that the
#             purifier lockfile locks (nix/lib/lock.nix): the downloads,
#             each with `systems`, the git repositories Yarn clones, and
#             the Yarn release from repo.yarnpkg.com
#   outputs   the project's packages by name, as { version, dir, bin }
#             (nix/lib/workspaces.nix)
#   problems  why the lockfiles cannot be used, each naming the command
#             that fixes it
#
# The builder passes it to `checkLock` of the purifier library. A missing
# download shows only when Yarn requests it, because the yarn.lock of Yarn
# Berry, which names the packages, is YAML, which Nix does not read.
{ lib }:
{
  # The root of the Yarn project.
  src,
  # Yarn's lockfile.
  yarnLock ? src + "/yarn.lock",
  # The purifier lockfile.
  lockFile ? src + "/yarn-berry-purifier.lock.json",
}:
let
  lock = import ./lock.nix { inherit lib yarnLock lockFile; };
in
{
  purifier = "yarn-berry-purifier";
  inherit (lock) entries problems;
  outputs = lib.mapAttrs (_: p: {
    inherit (p) version dir bin;
  }) (import ./workspaces.nix { inherit lib src; });
}
