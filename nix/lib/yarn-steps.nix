# SPDX-License-Identifier: MIT
#
# The shell steps that run a Yarn Berry project offline in the sandbox.
{
  lib,
  fetchurl,
  # The Node.js that runs Yarn.
  node,
  # The plugin, which answers Yarn's downloads from `dependencies`.
  plugin,
  # The downloads, laid out by nix/lib/dependencies.nix.
  dependencies,
  # The Yarn release, as nix/lib/lock.nix returns it.
  yarnRelease,
}:
let
  yarnJs =
    if yarnRelease ? path then
      "./${yarnRelease.path}"
    else
      fetchurl {
        inherit (yarnRelease) url hash;
        name = "yarn-${yarnRelease.version}.js";
      };
in
{
  # Gives Yarn a home directory whose .yarnrc.yml loads the plugin, points
  # the plugin at the downloads, and defines `yarn` as the locked release.
  setup = ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    cat > "$HOME/.yarnrc.yml" << 'EOF'
    plugins:
      - path: ${plugin}
        spec: "@nix-purifiers/plugin-yarn-berry-purifier"
    EOF
    export BERRY_PURIFIER_SERVE=${dependencies}
    # `git clone` of a locked repository clones the copy in the served
    # directory.
    export GIT_CONFIG_COUNT=${toString (builtins.length dependencies.gitConfig)}
    ${lib.concatImapStrings (i: c: ''
      export GIT_CONFIG_KEY_${toString (i - 1)}=${lib.escapeShellArg c.key}
      export GIT_CONFIG_VALUE_${toString (i - 1)}=${lib.escapeShellArg c.value}
    '') dependencies.gitConfig}
    export YARN_GLOBAL_FOLDER="$TMPDIR/yarn-global"
    export YARN_ENABLE_TELEMETRY=0
    export YARN_ENABLE_INLINE_BUILDS=1
    export YARN_ENABLE_PROGRESS_BARS=0
    # node-gyp takes the headers of the Node.js that runs it rather than
    # downloading them.
    export npm_config_nodedir=${node}
    yarnJs="$(realpath ${yarnJs})"
    yarn() {
      ${lib.getExe node} "$yarnJs" "$@"
    }
  '';
}
