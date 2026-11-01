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
#   <path>                    each document the lockfile holds as text
#   npm-locks/<hash>.json     the package-lock.json files that the lock run
#                             resolved for git dependencies that name npm in
#                             packageManager and have none
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
  # The documents the lockfile holds as text, as nix/lib/lock.nix returns
  # them.
  texts ? [ ],
  # The resolved package-lock.json files, as nix/lib/lock.nix returns them.
  npmLocks ? [ ],
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

  # The checkout of a locked commit, without its .git directory, whose hash
  # is reproducible.
  checkout =
    r:
    fetchgit {
      inherit (r.git) url rev;
      inherit (r) hash;
      fetchSubmodules = r.git.submodules;
    };

  byRemote = lib.groupBy (r: r.remote) repositories;
  remoteKey = remote: builtins.hashString "sha256" remote;

  # A repository with every locked commit of one remote, each on its own
  # branch, which `git clone` copies. Each commit is rebuilt from its
  # checkout and its raw commit object: the checkout's files make the
  # commit's tree, and the object, which names that tree, hashes to the
  # locked commit only when the tree matches. The commits' parents are
  # absent, so the repository is shallow at each of them.
  combined =
    rs:
    runCommand "yarn-berry-purifier-repository"
      (
        {
          nativeBuildInputs = [ git ];
          passAsFile = map (r: "commit_${r.git.rev}") rs;
        }
        // lib.listToAttrs (map (r: lib.nameValuePair "commit_${r.git.rev}" r.git.commitObject) rs)
      )
      ''
        git init -q --bare "$out"
        export GIT_DIR="$out"
        ${lib.concatMapStrings (r: ''
          export GIT_INDEX_FILE="$TMPDIR/index-${r.git.rev}"
          git --work-tree=${checkout r} add -A --force
          tree="$(git write-tree)"
          object="$(base64 -d < "$commit_${r.git.rev}Path" | git hash-object -t commit -w --stdin)"
          if [ "$object" != ${r.git.rev} ]; then
            echo "yarn-berry-purifier: the checkout and commit object of ${r.git.url} make commit $object (tree $tree), not ${r.git.rev}" >&2
            exit 1
          fi
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
        mkdir -p "$out/external" "$out/git" "$out/repositories"
        cp -rs --no-preserve=mode ${dependencies}/. "$out"
        ${lib.concatMapStrings (e: ''
          ln -s ${builtins.toFile "${e.manifestHash}.lock" e.yarnLock} "$out/external/${e.manifestHash}.lock"
        '') externals}
        ${lib.concatMapStrings (r: ''
          ln -s ${checkout r} "$out/${r.path}"
        '') repositories}
        mkdir -p "$out/npm-locks"
        ${lib.concatMapStrings (n: ''
          ln -s ${builtins.toFile "${n.manifestHash}.json" n.packageLock} "$out/npm-locks/${n.manifestHash}.json"
        '') npmLocks}
        ${lib.concatMapStrings (t: ''
          mkdir -p "$out/$(dirname ${lib.escapeShellArg t.path})"
          ln -s ${builtins.toFile "document" t.text} "$out"/${lib.escapeShellArg t.path}
        '') texts}
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
