# SPDX-License-Identifier: MIT
#
# The directory the plugin serves from: the locked downloads, laid out by
# nix/lib/dependencies.nix, and under external/ the yarn.lock files that the
# lock run resolved for git and GitHub dependencies whose repositories have
# none, each named after the SHA-256 of the repository's package.json.
{
  lib,
  runCommand,
  callPackage,
  # The downloads, as nix/lib/lock.nix returns them.
  downloads,
  # The external yarn.lock files, as nix/lib/lock.nix returns them.
  externals,
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
in
runCommand "yarn-berry-purifier-served"
  {
    preferLocalBuild = true;
    allowSubstitutes = false;
    passthru = { inherit dependencies; };
  }
  ''
    mkdir -p "$out/external"
    cp -rs --no-preserve=mode ${dependencies}/. "$out"
    ${lib.concatMapStrings (e: ''
      ln -s ${builtins.toFile "${e.key}.lock" e.yarnLock} "$out/external/${e.key}.lock"
    '') externals}
  ''
