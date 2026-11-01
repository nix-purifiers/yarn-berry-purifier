# SPDX-License-Identifier: MIT
#
# Yarn Berry with the yarn-berry-purifier plugin loaded, for any project
# and without a change to it. Yarn reads plugins from the .yarnrc.yml files
# of the project, the directories above it and the home directory, so the
# wrapper gives Yarn a temporary home directory whose .yarnrc.yml holds the
# settings of the user's own ~/.yarnrc.yml and loads the plugin. The plugin
# gives lifecycle scripts the real home directory back.
#
# With the plugin loaded, `yarn purifier lock`, `update`, `prefetch` and
# `publish` are the commands that `yarn-berry-purifier` runs, and in a
# project with a purifier lockfile, Yarn installs offline from the locked
# downloads, which Nix builds into the .yarn-berry-purifier directory beside
# the lockfile. Yarn delegates to the release that .yarnrc.yml names in
# yarnPath, as it does without the wrapper.
{
  lib,
  writeShellApplication,
  coreutils,
  gnugrep,
  gawk,
  git,
  nix-prefetch-git,
  nodejs,
  pkgs,
  plugin,
  # Yarn Berry from nixpkgs. Inside this flake's package scope the name
  # `yarn` is this wrapper, so the argument has another name.
  yarnBerry ? pkgs.yarn-berry,
}:
writeShellApplication {
  name = "yarn";
  # The lock command records git dependencies with git and
  # nix-prefetch-git.
  runtimeInputs = [
    coreutils
    gnugrep
    gawk
    nodejs
    git
    nix-prefetch-git
  ];
  text = ''
    # Purifier commands create and manage locks; native commands can run
    # in unconfigured projects without loading the integration.
    if [ "''${1:-}" != purifier ] && [ "''${BERRY_PURIFIER:-1}" = 0 ]; then
      exec ${lib.getExe yarnBerry} "$@"
    fi
    if [ "''${1:-}" != purifier ] && [ "''${BERRY_PURIFIER_RECORD:-}''${BERRY_PURIFIER_SERVE:-}" = "" ]; then
      dir="$PWD"
      lock="''${YARN_BERRY_PURIFIER_LOCKFILE:-}"
      while [ -z "$lock" ]; do
        if [ -e "$dir/yarn-berry-purifier.lock.json" ]; then
          lock="$dir/yarn-berry-purifier.lock.json"
        elif [ -f "$dir/yarn.lock" ] || [ "$dir" = / ]; then
          break
        else
          dir="$(dirname "$dir")"
        fi
      done
      if [ -z "$lock" ]; then
        echo "yarn-berry-purifier: warning: no yarn-berry-purifier.lock.json found; running yarn impurely. Run \`yarn-berry-purifier lock\` to use Nix-resolved dependencies." >&2
        exec ${lib.getExe yarnBerry} "$@"
      fi
    fi
    realHome="''${BERRY_PURIFIER_HOME:-$HOME}"
    home="$(mktemp -d "''${TMPDIR:-/tmp}/yarn-berry-purifier-home.XXXXXX")"
    trap 'rm -rf "$home"' EXIT
    entry='  - path: "${plugin}/purifier.cjs"
        spec: "@nix-purifiers/plugin-yarn-berry-purifier"'
    if [ -f "$realHome/.yarnrc.yml" ] && grep -q '^plugins:[[:space:]]*$' "$realHome/.yarnrc.yml"; then
      awk -v entry="$entry" '{ print } /^plugins:[[:space:]]*$/ { print entry }' "$realHome/.yarnrc.yml" > "$home/.yarnrc.yml"
    else
      { cat "$realHome/.yarnrc.yml" 2> /dev/null || true; printf 'plugins:\n%s\n' "$entry"; } > "$home/.yarnrc.yml"
    fi
    # Yarn Classic, which Yarn runs to pack git dependencies that use it,
    # reads the user's own ~/.yarnrc, and a mutex, because Yarn packs those
    # dependencies in parallel into a cache that only one Yarn Classic may
    # write at a time.
    { cat "$realHome/.yarnrc" 2> /dev/null || true; echo "--mutex \"file:$home/yarn-classic.mutex\""; } > "$home/.yarnrc"
    # Yarn's cache and global folder stay where they are without the
    # wrapper.
    export YARN_GLOBAL_FOLDER="''${YARN_GLOBAL_FOLDER:-$realHome/.yarn/berry}"
    export BERRY_PURIFIER_HOME="$realHome"
    HOME="$home" ${lib.getExe yarnBerry} "$@"
  '';
}
