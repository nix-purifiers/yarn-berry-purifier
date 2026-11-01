# SPDX-License-Identifier: MIT
#
# Reads yarn-berry-purifier.lock.json, which `yarn-berry-purifier lock`
# writes, at evaluation time. It returns
#
#   downloads   the files the install fetches on `system`, as entries of the
#               shared purifier library. A file entry is
#               { path, url, mirrors, hash }: `path` is where the plugin
#               looks the URL up, `mirrors` lists other URLs that serve the
#               same file, and `hash` is its SRI hash. The lockfile leaves
#               out `mirrors`, which follow from the URL. An inline entry,
#               { path, contents }, holds a small JSON document the install
#               reads, such as the list of Yarn releases, which changes as
#               releases appear
#   externals   the yarn.lock files that the lock run resolved for git and
#               GitHub dependencies whose repositories have none, as
#               { manifestHash, yarnLock }: `manifestHash` is the SHA-256 of the
#               repository's package.json, by which the plugin finds it
#   npmLocks    the package-lock.json files that the lock run resolved for
#               git and GitHub dependencies that name npm in packageManager
#               and have none, as { manifestHash, packageLock }
#   repositories the git repositories Yarn clones, as
#               git entries of the shared purifier library with the extra
#               field `remote`, the URL Yarn clones the repository from:
#               a checkout of commit `rev` with its .git directory
#   yarn        the Yarn release that runs the install: { path } for a
#               release in the project, which .yarnrc.yml names in yarnPath,
#               or { version, url, hash } for a release from
#               repo.yarnpkg.com
#   release     the file entry of a release from repo.yarnpkg.com, or null
#               for a release in the project
#
# The lock run installs once for each system it covers, so a download
# that only one platform installs, such as one of esbuild's per-platform
# binaries, lists only the systems that fetch it.
#
# The lockfile records `version`, the version of its format, and
# `contentHash`, the SRI SHA-256 of the lockfile without `contentHash` as
# builtins.toJSON writes it: keys sorted and no whitespace. The plugin
# computes the same hash when it writes the lockfile, so a lockfile changed
# by hand fails here.
{
  lib,
  # The purifier lockfile.
  lockFile,
  # The project's yarn.lock, which the purifier lockfile was written for.
  yarnLock,
  # The Nix system the install runs on.
  system,
}:
let
  lock = lib.importJSON lockFile;

  sri =
    text:
    builtins.convertHash {
      hash = builtins.hashString "sha256" text;
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };

  yarnLockHash = sri (builtins.readFile yarnLock);

  name = toString lockFile;
  fix = "Run `yarn-berry-purifier lock`.";

  # A download entry has a path and the systems that fetch it, and either
  # the text of a small response or the URL and hash of a file.
  validEntry =
    d:
    builtins.isAttrs d
    && builtins.isString (d.path or null)
    && builtins.isList (d.systems or null)
    && (
      builtins.isString (d.contents or null)
      || (builtins.isString (d.url or null) && builtins.isString (d.hash or null))
    );

  # The other URLs that serve a download's file: Yarn's registry and npm's
  # registry serve the same tarballs at the same paths. The plugin's
  # registryMirrors has the same rule.
  mirrorsOf =
    url:
    let
      yarn = "https://registry.yarnpkg.com/";
      npm = "https://registry.npmjs.org/";
    in
    if lib.hasPrefix yarn url then
      [ (npm + lib.removePrefix yarn url) ]
    else if lib.hasPrefix npm url then
      [ (yarn + lib.removePrefix npm url) ]
    else
      [ ];
  invalidEntries = builtins.filter (d: !(validEntry d)) (lock.downloads or [ ]);

  checked =
    if !(builtins.isAttrs lock) then
      throw "yarn-berry-purifier: ${name} holds no JSON object. ${fix}"
    else if lock.version or null != 1 then
      throw "yarn-berry-purifier: ${name} has version ${
        builtins.toJSON (lock.version or null)
      }, and this yarn-berry-purifier reads version 1. ${fix}"
    else if !(builtins.isString (lock.contentHash or null)) then
      throw "yarn-berry-purifier: ${name} lacks its `contentHash`. ${fix}"
    else if lock.contentHash != sri (builtins.toJSON (removeAttrs lock [ "contentHash" ])) then
      throw "yarn-berry-purifier: ${name} was changed after it was written; its contentHash does not match. ${fix}"
    else if
      !(builtins.isList (lock.downloads or null)) || !(builtins.isString (lock.inputsHash or null))
    then
      throw "yarn-berry-purifier: ${name} lacks its `downloads` list or its `inputsHash`. ${fix}"
    else if invalidEntries != [ ] then
      throw "yarn-berry-purifier: ${name} has a malformed download entry at path ${
        builtins.toJSON ((builtins.head invalidEntries).path or null)
      }. ${fix}"
    else if lock.inputsHash != yarnLockHash then
      throw "yarn-berry-purifier: ${name} was written for another yarn.lock. ${fix}"
    else if !(builtins.any (d: lib.elem system d.systems) lock.downloads) && lock.downloads != [ ] then
      throw "yarn-berry-purifier: ${name} covers no download for ${system}. Run `yarn-berry-purifier lock --system ${system}`."
    else
      lock;

  forSystem = map (
    d: removeAttrs d [ "systems" ] // lib.optionalAttrs (d ? url) { mirrors = mirrorsOf d.url; }
  ) (builtins.filter (d: lib.elem system d.systems) checked.downloads);
in
{
  downloads = forSystem;
  inherit (checked) yarn;
  release =
    if checked.yarn ? url then
      {
        path = "yarn-${checked.yarn.version}.js";
        inherit (checked.yarn) url hash;
        mirrors = [ ];
      }
    else
      null;
  externals = checked.externals or [ ];
  npmLocks = checked.npmLocks or [ ];
  repositories = checked.repositories or [ ];
}
