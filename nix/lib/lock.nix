# SPDX-License-Identifier: MIT
#
# Reads yarn-berry-purifier.lock.json, which `yarn purifier lock` writes, at
# evaluation time. It returns
#
#   downloads   the files the install fetches on `system`, as
#               { path, url, mirrors, hash }: `path` is where the plugin
#               looks the URL up, `mirrors` lists other URLs that serve the
#               same file, and `hash` is its SRI hash
#   texts       the small JSON documents the install reads, such as the list
#               of Yarn releases, as { path, text }; they change as releases
#               appear, so the purifier lockfile holds their text
#   externals   the yarn.lock files that the lock run resolved for git and
#               GitHub dependencies whose repositories have none, as
#               { manifestHash, yarnLock }: `manifestHash` is the SHA-256 of the
#               repository's package.json, by which the plugin finds it
#   npmLocks    the package-lock.json files that the lock run resolved for
#               git and GitHub dependencies that name npm in packageManager
#               and have none, as { manifestHash, packageLock }
#   repositories the git repositories Yarn clones, as
#               { path, git = { url, rev, submodules, leaveDotGit }, hash,
#               remote }: a checkout of commit `rev` with its .git
#               directory, and `remote`, the URL Yarn clones it from
#   yarn        the Yarn release that runs the install: { path } for a
#               release in the project, which .yarnrc.yml names in yarnPath,
#               or { version, url, hash } for a release from
#               repo.yarnpkg.com
#
# The lock run installs once for each system it covers, so a download
# that only one platform installs, such as one of esbuild's per-platform
# binaries, lists only the systems that fetch it.
{
  lib,
  # The purifier lockfile.
  lockFile,
  # The project's yarn.lock, which the purifier lockfile was written for.
  yarnLockFile,
  # The Nix system the install runs on.
  system,
}:
let
  lock = lib.importJSON lockFile;

  yarnLockHash = builtins.convertHash {
    hash = builtins.hashFile "sha256" yarnLockFile;
    hashAlgo = "sha256";
    toHashFormat = "sri";
  };

  checked =
    if lock.format or null != 1 then
      throw "yarn-berry-purifier: ${toString lockFile} has format ${toString (lock.format or null)}; this version reads format 1. Run `yarn purifier lock`."
    else if lock.inputsHash != yarnLockHash then
      throw "yarn-berry-purifier: yarn.lock changed since ${baseNameOf (toString lockFile)} was written. Run `yarn purifier lock`."
    else if !(builtins.any (d: lib.elem system d.systems) lock.downloads) && lock.downloads != [ ] then
      throw "yarn-berry-purifier: ${baseNameOf (toString lockFile)} covers no download for ${system}. Run `yarn purifier lock --system ${system}`."
    else
      lock;
in
let
  forSystem = map (d: removeAttrs d [ "systems" ]) (
    builtins.filter (d: lib.elem system d.systems) checked.downloads
  );
in
{
  downloads = builtins.filter (d: !(d ? text)) forSystem;
  texts = builtins.filter (d: d ? text) forSystem;
  inherit (checked) yarn;
  externals = checked.externals or [ ];
  npmLocks = checked.npmLocks or [ ];
  repositories = checked.repositories or [ ];
}
