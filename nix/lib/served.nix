# SPDX-License-Identifier: MIT
#
# The directory the plugin serves from:
#
#   <path>                    each locked download and each document the
#                             lockfile holds inline, laid out by the
#                             shared purifier library
#   git/<rev>                 a checkout of each locked commit of a git
#                             repository, with its .git directory, which
#                             the shared purifier library rebuilds
#   external/<hash>.lock      the yarn.lock files that the lock run resolved
#                             for git and GitHub dependencies whose
#                             repositories have none, each named after the
#                             SHA-256 of the repository's package.json
#   npm-locks/<hash>.json     the package-lock.json files that the lock run
#                             resolved for git dependencies that name npm in
#                             packageManager and have none
#   repositories/<hash>       for each repository Yarn clones, a git
#                             repository holding every locked commit of it,
#                             each on a branch purifier-<rev>
#
# `passthru.gitConfig` lists the git settings, as { key, value }, that make
# `git clone <remote>` clone the repository under repositories/.
{
  lib,
  pkgs,
  runCommand,
  git,
  # The `purifier` namespace of the shared library.
  purifier,
  # The downloads, as nix/lib/lock.nix returns them.
  downloads,
  # The external yarn.lock files, as nix/lib/lock.nix returns them.
  externals,
  # The git repositories, as nix/lib/lock.nix returns them.
  repositories ? [ ],
  # The resolved package-lock.json files, as nix/lib/lock.nix returns them.
  npmLocks ? [ ],
  # Replaces the fetcher of the locked downloads.
  fetchurl ? null,
  # Replaces the fetcher of the git checkouts.
  fetchgit ? null,
}:
let
  fetchers = {
    inherit pkgs;
  }
  // lib.optionalAttrs (fetchurl != null) { inherit fetchurl; }
  // lib.optionalAttrs (fetchgit != null) { inherit fetchgit; };

  dependencies = purifier.tree (
    fetchers
    // {
      name = "yarn-berry-purifier-dependencies";
      entries = downloads ++ repositories;
    }
  );

  byRemote = lib.groupBy (r: r.remote) repositories;
  remoteKey = remote: builtins.hashString "sha256" remote;

  # A repository with every locked commit of one remote, each on its own
  # branch, which `git clone` copies. The library rebuilds the .git
  # directory of each checkout as loose objects and fails unless the commit
  # object hashes to the locked commit; this repository takes those
  # objects. The commits' parents are absent, so the repository is shallow
  # at each of them.
  combined =
    rs:
    runCommand "yarn-berry-purifier-repository" { nativeBuildInputs = [ git ]; } ''
      git init -q --bare "$out"
      export GIT_DIR="$out"
      ${lib.concatMapStrings (r: ''
        cp -r --no-preserve=mode ${purifier.fetchEntry fetchers r}/.git/objects/. "$out/objects"
        echo ${r.git.rev} >> "$out/shallow"
        git update-ref refs/heads/purifier-${r.git.rev} ${r.git.rev}
      '') rs}
      git symbolic-ref HEAD refs/heads/purifier-${(builtins.head rs).git.rev}
    '';

  served =
    runCommand "yarn-berry-purifier-served"
      {
        preferLocalBuild = true;
        allowSubstitutes = false;
        passthru = {
          inherit dependencies;
        };
      }
      ''
        mkdir -p "$out/external" "$out/npm-locks" "$out/repositories"
        cp -rs --no-preserve=mode ${dependencies}/. "$out"
        ${lib.concatMapStrings (e: ''
          ln -s ${builtins.toFile "${e.manifestHash}.lock" e.yarnLock} "$out/external/${e.manifestHash}.lock"
        '') externals}
        ${lib.concatMapStrings (n: ''
          ln -s ${builtins.toFile "${n.manifestHash}.json" n.packageLock} "$out/npm-locks/${n.manifestHash}.json"
        '') npmLocks}
        ${lib.concatStrings (
          lib.mapAttrsToList (remote: rs: ''
            ln -s ${combined rs} "$out/repositories/${remoteKey remote}"
          '') byRemote
        )}
      '';
in
served
// {
  gitConfig = [
    {
      key = "safe.directory";
      value = "*";
    }
  ]
  ++ lib.mapAttrsToList (remote: _: {
    key = "url.${served}/repositories/${remoteKey remote}.insteadOf";
    value = remote;
  }) byRemote;
}
