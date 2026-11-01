# SPDX-License-Identifier: MIT
#
# The shell steps that run a Yarn Berry project offline in the sandbox.
{
  lib,
  fetchurl,
  runtimeShell,
  # The Node.js that runs Yarn.
  node,
  # The plugin, which answers Yarn's downloads from `dependencies`.
  plugin,
  # The directory nix/lib/served.nix lays out.
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
      - path: ${plugin}/purifier.cjs
        spec: "@nix-purifiers/plugin-yarn-berry-purifier"
    EOF
    export BERRY_PURIFIER_SERVE=${dependencies}
    # When Yarn packs a git dependency with npm or Yarn Classic, npm reads
    # the served tarballs from its cache by integrity, offline, and Yarn
    # Classic reads them from its offline mirror. Yarn passes these settings
    # through to both; it would reject unknown YARN_ settings.
    export npm_config_cache="$TMPDIR/npm-cache"
    mkdir -p "$npm_config_cache"
    if [ -d ${dependencies}/npm-cache ]; then
      cp -rs --no-preserve=mode ${dependencies}/npm-cache/. "$npm_config_cache"
    fi
    export npm_config_offline=true
    export npm_config_audit=false
    export npm_config_fund=false
    export npm_config_update_notifier=false
    export npm_config_yarn_offline_mirror=${dependencies}/yarn-mirror
    # Yarn packs git dependencies in parallel, and Yarn Classic installs
    # into a shared cache that only one Yarn Classic may write at a time.
    echo "--mutex \"file:$TMPDIR/yarn-classic.mutex\"" > "$HOME/.yarnrc"
    # A git dependency that names npm in packageManager and has no lockfile
    # gets the package-lock.json the lock run resolved for it, from this
    # `npm` in front of npm on the PATH.
    mkdir -p "$TMPDIR/purifier-bin"
    cat > "$TMPDIR/purifier-bin/npm" << 'EOF'
    #!${runtimeShell}
    if [ -f package.json ] && [ ! -f package-lock.json ]; then
      lock="${dependencies}/npm-locks/$(sha256sum package.json | cut -d' ' -f1).json"
      if [ -f "$lock" ]; then
        cp "$lock" package-lock.json
        chmod u+w package-lock.json
      fi
    fi
    exec ${node}/bin/npm "$@"
    EOF
    chmod +x "$TMPDIR/purifier-bin/npm"
    export PATH="$TMPDIR/purifier-bin:$PATH"
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
