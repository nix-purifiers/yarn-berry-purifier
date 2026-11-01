# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked downloads.
{
  pkgs,
  # The flake's default package overlay, which adds buildYarnBerryProject.
  overlay,
}:
let
  inherit (pkgs) lib;

  # Every fixture builds the way a consumer's package does: through
  # buildYarnBerryProject of a package set the overlay applies to.
  withOverlay = pkgs.extend overlay;
  inherit (withOverlay) buildYarnBerryProject;
  inherit (withOverlay.yarn-berry-purifier) plugin;

  # One package with a build script, a test script, a command, a
  # dependency and a dev dependency, installed with Plug'n'Play.
  app = buildYarnBerryProject {
    src = ./fixtures/app;
    doCheck = true;
  };

  # A workspace that depends on another workspace, a GitHub dependency, a
  # patch that adds a file, and portal:, link: and file: dependencies.
  sources = buildYarnBerryProject { src = ./fixtures/sources; };

  # Reads a purifier lockfile written inline, for a yarn.lock with the
  # given text.
  readLock =
    system: lock: yarnLock:
    import ../nix/lib/lock.nix {
      inherit lib system;
      lockFile = builtins.toFile "yarn-berry-purifier.lock.json" (builtins.toJSON lock);
      yarnLockFile = builtins.toFile "yarn.lock" yarnLock;
    };
  yarnLockText = "# a yarn.lock\n";
  yarnLockHash = builtins.convertHash {
    hash = builtins.hashString "sha256" yarnLockText;
    hashAlgo = "sha256";
    toHashFormat = "sri";
  };
  release = {
    version = "4.18.1";
    url = "https://repo.yarnpkg.com/4.18.1/packages/yarnpkg-cli/bin/yarn.js";
    hash = "sha512-suHnUk9lTydJ0ytOvLRiJHPLW8vEhd8gB+EqFU5QFipNeVUmdovF9bj4Fxe/153rJHKBPYb7WuLrVR+pyHKwjw==";
  };

  # The repository of the git dependency in fixtures/git, and a stand-in for
  # nix-prefetch-git that prints a hash without fetching.
  gitRepository = pkgs.callPackage ./git-repository.nix { };
  fakePrefetchGit = pkgs.writeShellScript "nix-prefetch-git" ''
    echo '{ "hash": "${lib.fakeHash}" }'
  '';

  # A lockfile check passes when `assertion` holds; it fails with
  # `message` otherwise.
  evalCheck =
    name: assertion: message:
    if assertion then
      pkgs.runCommand name { } "touch $out"
    else
      throw "yarn-berry-purifier check ${name}: ${message}";

  # Runs Yarn Berry with the plugin loaded from a home directory's
  # .yarnrc.yml, as the builder does.
  yarnWithPlugin = ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    printf 'plugins:\n  - path: %s\n    spec: "@nix-purifiers/plugin-yarn-berry-purifier"\n' ${plugin} > "$HOME/.yarnrc.yml"
    export YARN_ENABLE_TELEMETRY=0
    export YARN_GLOBAL_FOLDER="$TMPDIR/yarn-global"
  '';
in
{
  # The package's command prints what its build script wrote, and its dev
  # dependency stays out of the installed package.
  app =
    pkgs.runCommand "app-check"
      {
        nativeBuildInputs = [ app.packages.hello-berry ];
      }
      ''
        hello-berry | grep -q 'hello-berry: built by the build script (3 is odd: true)'
        if [ -e ${app.packages.hello-berry}/lib/node_modules/is-odd ]; then
          echo "the dev dependency is-odd is installed" >&2
          exit 1
        fi
        tar -xzOf ${app.packages.hello-berry.tarball}/package.tgz package/dist/message.js \
          | grep -q 'built by the build script'
        touch $out
      '';

  # Every dependency source of the sources fixture resolves in the
  # installed package.
  sources =
    pkgs.runCommand "sources-check"
      {
        nativeBuildInputs = [ sources.packages.sources-cli ];
      }
      ''
        sources-cli | grep -qx 'workspace .github patch portal link file tarball'
        touch $out
      '';

  # A workspace root without commands is no package of its own.
  workspaces-root = evalCheck "workspaces-root" (
    !(sources.packages ? sources)
  ) "the workspace root is a package";

  # A build fetches only the downloads that the lock run made for its
  # system.
  platform-filter =
    let
      lock = {
        format = 1;
        inputsHash = yarnLockHash;
        yarn = release;
        downloads = [
          {
            path = "https/registry.yarnpkg.com/@esbuild%2flinux-x64/-/linux-x64-0.25.0.tgz";
            url = "https://registry.yarnpkg.com/@esbuild%2flinux-x64/-/linux-x64-0.25.0.tgz";
            mirrors = [ ];
            hash = "sha512-9yl91rHw/cpwMCNytUDxwj2XjFpxML0y9HAOH9pNVQDpQrBxHy01Dx+vaMu0N1CKa/RzBD2hB4u//nfc+Sd3Cw==";
            systems = [ "x86_64-linux" ];
          }
          {
            path = "https/registry.yarnpkg.com/@esbuild%2flinux-arm64/-/linux-arm64-0.25.0.tgz";
            url = "https://registry.yarnpkg.com/@esbuild%2flinux-arm64/-/linux-arm64-0.25.0.tgz";
            mirrors = [ ];
            hash = "sha512-9QAQjTWNDM/Vk2bgBl17yWuZxZNQIF0OUUuPZRKoDtqF2k4EtYbpyiG5/Dk7nqeK6kIJWPYldkOcBqjXjrUlmg==";
            systems = [ "aarch64-linux" ];
          }
        ];
      };
      urls = system: map (d: d.url) (readLock system lock yarnLockText).downloads;
    in
    evalCheck "platform-filter" (
      urls "x86_64-linux"
      == [ "https://registry.yarnpkg.com/@esbuild%2flinux-x64/-/linux-x64-0.25.0.tgz" ]
      &&
        urls "aarch64-linux" == [
          "https://registry.yarnpkg.com/@esbuild%2flinux-arm64/-/linux-arm64-0.25.0.tgz"
        ]
    ) "the downloads for x86_64-linux and aarch64-linux are not the matching esbuild package";

  # A purifier lockfile written for another yarn.lock fails evaluation.
  stale-lock =
    let
      result = builtins.tryEval (
        builtins.deepSeq
          (readLock "x86_64-linux" {
            format = 1;
            inputsHash = yarnLockHash;
            yarn = release;
            downloads = [ ];
          } "# another yarn.lock\n").downloads
          true
      );
    in
    evalCheck "stale-lock" (!result.success) "a purifier lockfile for another yarn.lock evaluated";

  # The plugin evaluates nix/lib/interactive.nix for a project; the
  # directory it builds is the one the sandboxed build of the project
  # serves from.
  interactive =
    let
      served = import ../nix/lib/interactive.nix {
        pkgs = withOverlay;
        lockFile = ./fixtures/app/yarn-berry-purifier.lock.json;
      };
    in
    evalCheck "interactive" (
      served.outPath == app.dependencies.outPath
    ) "the directory interactive use serves from differs from the one the build uses";

  # In the lock run, a nested Yarn records the yarn.lock it resolved for a
  # repository that had none, keyed by the hash of its package.json. The
  # project here has only a portal: dependency, so its install needs no
  # download.
  external-record =
    pkgs.runCommand "external-record-check"
      {
        nativeBuildInputs = [
          pkgs.yarn-berry
          pkgs.jq
        ];
      }
      ''
        ${yarnWithPlugin}
        cp -r ${./fixtures/external} project
        chmod -R u+w project
        cd project
        touch yarn.lock
        export BERRY_PURIFIER_RECORD="$TMPDIR/records"
        export BERRY_PURIFIER_MAIN=/nonexistent
        touch "$BERRY_PURIFIER_RECORD"
        yarn install --mode=skip-build
        key="$(sha256sum package.json | cut -d' ' -f1)"
        jq -e --arg key "$key" 'select(.external == $key) | .yarnLock | contains("portal-dependency@portal:")' \
          "$BERRY_PURIFIER_RECORD"
        touch $out
      '';

  # In a sandboxed build, the plugin writes the recorded yarn.lock into a
  # repository whose yarn.lock is empty, before Yarn reads it.
  external-restore =
    pkgs.runCommand "external-restore-check"
      {
        nativeBuildInputs = [ pkgs.yarn-berry ];
      }
      ''
        ${yarnWithPlugin}
        cp -r ${./fixtures/external} project
        chmod -R u+w project
        cd project
        touch yarn.lock
        mkdir -p "$TMPDIR/served/external"
        echo '# the recorded yarn.lock' > "$TMPDIR/served/external/$(sha256sum package.json | cut -d' ' -f1).lock"
        export BERRY_PURIFIER_SERVE="$TMPDIR/served"
        yarn --version > /dev/null
        grep -qx '# the recorded yarn.lock' yarn.lock
        touch $out
      '';

  # `yarn purifier publish` builds the tarball nix/lib/publish.nix names,
  # which is the package's tarball output.
  publish-tarball =
    let
      tarball = import ../nix/lib/publish.nix {
        pkgs = withOverlay;
        src = ./fixtures/app;
        package = "hello-berry";
      };
    in
    evalCheck "publish-tarball" (
      tarball.outPath == (buildYarnBerryProject { src = ./fixtures/app; })
      .packages.hello-berry.tarball.outPath
    ) "the tarball the publish command builds differs from the package's tarball";

  # `yarn purifier publish` uploads the tarball byte for byte, through
  # Yarn's own publish request. The registry is a local server.
  publish =
    pkgs.runCommand "publish-check"
      {
        nativeBuildInputs = [
          pkgs.yarn-berry
          pkgs.nodejs
          pkgs.jq
        ];
      }
      ''
        ${yarnWithPlugin}
        node ${./registry.js} "$TMPDIR/port" "$TMPDIR/body" &
        while [ ! -s "$TMPDIR/port" ]; do sleep 0.1; done
        export YARN_NPM_PUBLISH_REGISTRY="http://127.0.0.1:$(cat "$TMPDIR/port")"
        export YARN_NPM_AUTH_TOKEN=token
        export YARN_UNSAFE_HTTP_WHITELIST=127.0.0.1
        cp -r ${./fixtures/app} project
        chmod -R u+w project
        cd project
        yarn purifier publish --tarball ${app.packages.hello-berry.tarball}/package.tgz
        jq -r '._attachments[].data' "$TMPDIR/body" | base64 -d > "$TMPDIR/uploaded.tgz"
        cmp "$TMPDIR/uploaded.tgz" ${app.packages.hello-berry.tarball}/package.tgz
        touch $out
      '';

  # The lock run of a project with a git dependency that Yarn clones. The
  # repository is the fixture repository, which git's insteadOf puts in
  # place of the dependency's URL, so the run needs no network;
  # nix-prefetch-git, which would fetch it, is replaced by a command that
  # prints a hash. The lockfile records the URL Yarn clones and the locked
  # commit. The check's output holds the yarn.lock and purifier lockfile of
  # the run, from which fixtures/git was made.
  git-record =
    pkgs.runCommand "git-record-check"
      {
        nativeBuildInputs = [
          pkgs.yarn-berry
          pkgs.git
          pkgs.jq
        ];
      }
      ''
        ${yarnWithPlugin}
        cp -r ${./fixtures/git} project
        chmod -R u+w project
        cd project
        rm -f yarn-berry-purifier.lock.json
        # The release in the project spares the lock run its download of
        # Yarn.
        mkdir -p .yarn/releases
        cp ${pkgs.yarn-berry}/bin/yarn .yarn/releases/yarn.cjs
        echo 'yarnPath: .yarn/releases/yarn.cjs' >> .yarnrc.yml
        export GIT_CONFIG_COUNT=2
        export GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
        export GIT_CONFIG_KEY_1=url.${gitRepository}.insteadOf
        export GIT_CONFIG_VALUE_1=https://git.example.invalid/git-dependency.git
        export BERRY_PURIFIER_PREFETCH_GIT=${fakePrefetchGit}
        yarn install --mode=skip-build
        yarn purifier lock --system x86_64-linux
        jq -c .repositories yarn-berry-purifier.lock.json
        jq -e '.repositories == [{
          path: "git/55e425bf63e80624db0138ef7ff3ff32fe4c7ab5",
          git: {
            url: "https://git.example.invalid/git-dependency.git",
            rev: "55e425bf63e80624db0138ef7ff3ff32fe4c7ab5",
            submodules: false,
            leaveDotGit: true
          },
          hash: "${lib.fakeHash}",
          remote: "https://git.example.invalid/git-dependency.git"
        }]' yarn-berry-purifier.lock.json
        mkdir -p "$out"
        cp yarn.lock yarn-berry-purifier.lock.json "$out"
      '';

  # The build of that project. Yarn clones the dependency in the sandbox
  # from the served repository, through the insteadOf settings of the
  # served directory, and packs it, which runs its prepack script.
  # `fetchgit` returns the fixture repository in place of a clone of the
  # dependency's URL.
  git-build =
    let
      project = buildYarnBerryProject {
        src = ./fixtures/git;
        fetchgit = _: gitRepository;
      };
    in
    pkgs.runCommand "git-build-check" { nativeBuildInputs = [ project.packages.uses-git-dependency ]; }
      ''
        uses-git-dependency | grep -qx 'cloned and packed'
        touch $out
      '';

  # The wrapper builds.
  yarn = withOverlay.yarn-berry-purifier.yarn;
}
