# SPDX-License-Identifier: MIT
#
# Yarn Berry with the yarn-berry-purifier plugin loaded, for any project
# and without a change to it. Yarn reads plugins from the .yarnrc.yml files
# of the project, the directories above it and the home directory, so the
# wrapper gives Yarn a temporary home directory whose .yarnrc.yml holds the
# settings of the user's own ~/.yarnrc.yml and loads the plugin. The plugin
# gives lifecycle scripts the real home directory back.
#
# With the plugin loaded, `yarn purifier lock` writes the purifier lockfile,
# `yarn purifier publish` publishes the tarball a sandboxed build packs,
# and in a project whose purifier lockfile matches its yarn.lock, Yarn
# installs offline from the locked downloads, which Nix builds under
# .yarn/purifier. Yarn delegates to the release that .yarnrc.yml names in
# yarnPath, as it does without the wrapper.
{
  lib,
  writeShellApplication,
  coreutils,
  nodejs,
  pkgs,
  plugin,
  # Yarn Berry from nixpkgs. Inside this flake's package scope the name
  # `yarn` is this wrapper, so the argument has another name.
  yarnBerry ? pkgs.yarn-berry,
}:
writeShellApplication {
  name = "yarn";
  runtimeInputs = [
    coreutils
    nodejs
  ];
  text = ''
    realHome="''${BERRY_PURIFIER_HOME:-$HOME}"
    home="$(mktemp -d "''${TMPDIR:-/tmp}/yarn-berry-purifier-home.XXXXXX")"
    trap 'rm -rf "$home"' EXIT
    entry='  - path: "${plugin}"
        spec: "@nix-purifiers/plugin-yarn-berry-purifier"'
    if [ -f "$realHome/.yarnrc.yml" ] && grep -q '^plugins:[[:space:]]*$' "$realHome/.yarnrc.yml"; then
      awk -v entry="$entry" '{ print } /^plugins:[[:space:]]*$/ { print entry }' "$realHome/.yarnrc.yml" > "$home/.yarnrc.yml"
    else
      { cat "$realHome/.yarnrc.yml" 2> /dev/null || true; printf 'plugins:\n%s\n' "$entry"; } > "$home/.yarnrc.yml"
    fi
    # Yarn's cache and global folder stay where they are without the
    # wrapper.
    export YARN_GLOBAL_FOLDER="''${YARN_GLOBAL_FOLDER:-$realHome/.yarn/berry}"
    export BERRY_PURIFIER_HOME="$realHome"
    HOME="$home" ${lib.getExe yarnBerry} "$@"
  '';
}
