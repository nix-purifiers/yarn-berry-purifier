# SPDX-License-Identifier: MIT
#
# The directory the plugin serves from:
#
#   <path>                    each locked download, laid out by
#                             nix/lib/dependencies.nix
#   external/<hash>.lock      the yarn.lock files that the lock run resolved
#                             for git and GitHub dependencies whose
#                             repositories have none, each named after the
#                             SHA-256 of the repository's package.json
#   git/<rev>                 a checkout of each locked commit of a git
#                             repository, with its .git directory
#   repositories/<hash>       for each repository Yarn clones, a git
#                             repository holding every locked commit of it,
#                             each on a branch purifier-<rev>
#
# `passthru.gitConfig` lists the git settings, as { key, value }, that make
# `git clone <remote>` clone the repository under repositories/.
{
  lib,
  runCommand,
  callPackage,
  fetchgit,
  git,
  # The downloads, as nix/lib/lock.nix returns them.
  downloads,
  # The external yarn.lock files, as nix/lib/lock.nix returns them.
  externals,
  # The git repositories, as nix/lib/lock.nix returns them.
  repositories ? [ ],
  # Replaces the fetcher of the locked downloads.
  fetchurl ? null,
}:
let
  dependencies = callPackage ./dependencies.nix (
    {
      inherit downloads;
    }
    // lib.optionalAttrs (fetchurl != null) { inherit fetchurl; }
  );

  checkout =
    r:
    fetchgit {
      inherit (r.git) url rev leaveDotGit;
      inherit (r) hash;
      fetchSubmodules = r.git.submodules;
    };

  byRemote = lib.groupBy (r: r.remote) repositories;
  remoteKey = remote: builtins.hashString "sha256" remote;

  # A repository with every locked commit of one remote, each on its own
  # branch, which `git clone` copies.
  combined =
    rs:
    runCommand "yarn-berry-purifier-repository" { nativeBuildInputs = [ git ]; } ''
      git init -q --bare "$out"
      ${lib.concatMapStrings (r: ''
        git -c safe.directory='*' -C "$out" fetch -q ${checkout r} HEAD:refs/heads/purifier-${r.git.rev}
        test "$(git -C "$out" rev-parse purifier-${r.git.rev})" = ${r.git.rev}
      '') rs}
      git -C "$out" symbolic-ref HEAD refs/heads/purifier-${(builtins.head rs).git.rev}
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
        mkdir -p "$out/external" "$out/git" "$out/repositories"
        cp -rs --no-preserve=mode ${dependencies}/. "$out"
        ${lib.concatMapStrings (e: ''
          ln -s ${builtins.toFile "${e.manifestHash}.lock" e.yarnLock} "$out/external/${e.manifestHash}.lock"
        '') externals}
        ${lib.concatMapStrings (r: ''
          ln -s ${checkout r} "$out/${r.path}"
        '') repositories}
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
