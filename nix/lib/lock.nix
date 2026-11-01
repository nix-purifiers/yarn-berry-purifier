# SPDX-License-Identifier: MIT
#
# Reads yarn-berry-purifier.lock.json, which `yarn-berry-purifier lock`
# writes, at evaluation time. It returns
#
#   problems    why the lockfile cannot be used, each naming the command
#               that fixes it; empty for a usable lockfile. Computing it
#               throws nothing, except for a file that is not JSON at all,
#               which builtins.fromJSON rejects with its own error.
#   entries     the download entries of the purifier library, or [] when
#               there are problems: the downloads, the git repositories
#               and the Yarn release. A file entry is
#               { path, url, mirrors, hash }: `path` is where the plugin
#               looks the URL up, `mirrors` lists other URLs that serve the
#               same file, and `hash` is its SRI hash. The lockfile leaves
#               out `mirrors`, which follow from the URL. An inline entry,
#               { path, contents }, holds a small JSON document the install
#               reads, such as the list of Yarn releases, which changes as
#               releases appear. A download keeps `systems`, the Nix systems
#               whose lock runs fetched it, so that one platform's package,
#               such as one of esbuild's per-platform binaries, is fetched
#               only there. A git entry, of a repository Yarn clones,
#               carries the extra field `remote`, the URL Yarn clones it
#               from.
#   yarn        the Yarn release that runs the install: { path } for a
#               release in the project, which .yarnrc.yml names in yarnPath,
#               or { version, url, hash } for a release from
#               repo.yarnpkg.com
#   release     the file entry of a release from repo.yarnpkg.com, or null
#               for a release in the project
#   externals   the yarn.lock files that the lock run resolved for git and
#               GitHub dependencies whose repositories have none, as
#               { manifestHash, yarnLock }: `manifestHash` is the SHA-256 of the
#               repository's package.json, by which the plugin finds it
#   npmLocks    the package-lock.json files that the lock run resolved for
#               git and GitHub dependencies that name npm in packageManager
#               and have none, as { manifestHash, packageLock }
#
# `yarn`, `release`, `externals` and `npmLocks` are read only when
# `problems` is empty.
#
# The lockfile records `version`, the version of its format, and
# `contentHash`, the SRI SHA-256 of the lockfile without `contentHash` as
# builtins.toJSON writes it: keys sorted and no whitespace. The plugin
# computes the same hash when it writes the lockfile, so a lockfile changed
# by hand is reported here.
{
  lib,
  # The purifier lockfile.
  lockFile,
  # The project's yarn.lock, which the purifier lockfile was written for.
  yarnLock,
}:
let
  name = toString lockFile;
  fix = "Run `yarn-berry-purifier lock`.";

  exists = builtins.pathExists lockFile;
  lock = if exists then lib.importJSON lockFile else null;

  sri =
    text:
    builtins.convertHash {
      hash = builtins.hashString "sha256" text;
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };

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
  invalidEntries = builtins.filter (d: !(validEntry d)) lock.downloads;

  # The first reason the lockfile cannot be used, or null.
  problem =
    if !exists then
      "yarn-berry-purifier: ${name} does not exist. ${fix}"
    else if !(builtins.isAttrs lock) then
      "yarn-berry-purifier: ${name} holds no JSON object. ${fix}"
    else if lock.version or null != 1 then
      "yarn-berry-purifier: ${name} has version ${
        builtins.toJSON (lock.version or null)
      }, and this yarn-berry-purifier reads version 1. ${fix}"
    else if !(builtins.isString (lock.contentHash or null)) then
      "yarn-berry-purifier: ${name} lacks its `contentHash`. ${fix}"
    else if lock.contentHash != sri (builtins.toJSON (removeAttrs lock [ "contentHash" ])) then
      "yarn-berry-purifier: ${name} was changed after it was written; its contentHash does not match. ${fix}"
    else if
      !(builtins.isList (lock.downloads or null))
      || !(builtins.isString (lock.inputsHash or null))
      || !(builtins.isAttrs (lock.yarn or null))
    then
      "yarn-berry-purifier: ${name} lacks its `downloads` list, its `inputsHash` or its `yarn`. ${fix}"
    else if invalidEntries != [ ] then
      "yarn-berry-purifier: ${name} has a malformed download entry at path ${
        builtins.toJSON ((builtins.head invalidEntries).path or null)
      }. ${fix}"
    else if lock.inputsHash != sri (builtins.readFile yarnLock) then
      "yarn-berry-purifier: ${name} was written for another yarn.lock. ${fix}"
    else
      null;

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

  release =
    if lock.yarn ? url then
      {
        path = "yarn-${lock.yarn.version}.js";
        inherit (lock.yarn) url hash;
        mirrors = [ ];
      }
    else
      null;
in
{
  problems = lib.optional (problem != null) problem;
  entries =
    if problem != null then
      [ ]
    else
      map (d: d // lib.optionalAttrs (d ? url) { mirrors = mirrorsOf d.url; }) lock.downloads
      ++ lock.repositories or [ ]
      ++ lib.optional (release != null) release;
  inherit (lock) yarn;
  inherit release;
  externals = lock.externals or [ ];
  npmLocks = lock.npmLocks or [ ];
}
