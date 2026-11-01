# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked downloads and the relock.
# The `conformance-*` checks are those of the purifier contract.
{
  pkgs,
  # The flake's default package overlay, which adds the plugin, the `yarn`
  # wrapper and the `yarn-berry-purifier` command.
  overlay,
  # The `purifier` namespace of the shared library, from the flake's
  # library.
  purifier,
  # The `yarn-berry-purifier` namespace of the flake's library.
  yarn-berry-purifier,
}:
let
  inherit (pkgs) lib;

  withOverlay = pkgs.extend overlay;
  inherit (withOverlay.yarn-berry-purifier) plugin;

  # Every fixture builds the way a consumer's package does: through the
  # builder of the flake's library.
  buildYarnBerryProject =
    args: yarn-berry-purifier.buildYarnBerryProject ({ pkgs = withOverlay; } // args);

  # One package with a build script, a test script, a command, a
  # dependency and a dev dependency, installed with Plug'n'Play.
  app = buildYarnBerryProject { src = ./fixtures/app; };

  # A workspace that depends on another workspace, a GitHub dependency, a
  # patch that adds a file, and portal:, link: and file: dependencies.
  sources = buildYarnBerryProject { src = ./fixtures/sources; };

  # The directory the plugin serves fixtures/app from in interactive use
  # and after `yarn-berry-purifier prefetch`.
  servedApp = import ../nix/lib/interactive.nix {
    inherit purifier;
    pkgs = withOverlay;
    lockFile = ./fixtures/app/yarn-berry-purifier.lock.json;
    yarnLock = ./fixtures/app/yarn.lock;
  };

  sri =
    text:
    builtins.convertHash {
      hash = builtins.hashString "sha256" text;
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };

  # A purifier lockfile with `version` 1 and the contentHash of its content,
  # as `yarn-berry-purifier lock` writes it.
  sealed =
    content:
    let
      withVersion = content // {
        version = 1;
      };
    in
    withVersion // { contentHash = sri (builtins.toJSON withVersion); };

  # The lock in memory of fixtures/app with a purifier lockfile written
  # inline, for a yarn.lock with the given text.
  readLock =
    lock: yarnLock:
    yarn-berry-purifier.readLock {
      src = ./fixtures/app;
      lockFile = builtins.toFile "yarn-berry-purifier.lock.json" (builtins.toJSON lock);
      yarnLock = builtins.toFile "yarn.lock" yarnLock;
    };
  # Whether readLock reports the lockfile as usable.
  usable = lock: yarnLock: (readLock lock yarnLock).problems == [ ];
  # Whether readLock reports problems with the lockfile, each naming the
  # command that fixes it, and gives no entries.
  reported =
    read:
    read.problems != [ ]
    && builtins.all (lib.hasInfix "Run `yarn-berry-purifier lock`") read.problems
    && read.entries == [ ];
  rejected = lock: yarnLock: reported (readLock lock yarnLock);
  yarnLockText = "# a yarn.lock\n";
  yarnLockHash = sri yarnLockText;
  release = {
    version = "4.18.1";
    url = "https://repo.yarnpkg.com/4.18.1/packages/yarnpkg-cli/bin/yarn.js";
    hash = "sha512-suHnUk9lTydJ0ytOvLRiJHPLW8vEhd8gB+EqFU5QFipNeVUmdovF9bj4Fxe/153rJHKBPYb7WuLrVR+pyHKwjw==";
  };
  download = {
    path = "https/registry.yarnpkg.com/a/-/a-1.0.0.tgz";
    url = "https://registry.yarnpkg.com/a/-/a-1.0.0.tgz";
    hash = "sha512-dKlgKLTrnih8yfGKBozBsVcGe0mS1/aKhCGPevK47XUNBMB+L0qk6zFw3YQnOFqH8dWqP9KNw9V+g1oOw4ew2g==";
    systems = [ "x86_64-linux" ];
  };
  # The content of a well-formed lockfile for yarnLockText. The negative
  # checks change one part of it each.
  goodLock = {
    inputsHash = yarnLockHash;
    yarn = release;
    downloads = [ download ];
  };

  # The repository of the git dependency in fixtures/git, and a stand-in for
  # nix-prefetch-git that prints a hash without fetching.
  makeRepository = pkgs.callPackage ./git-repository.nix { };
  gitRepository = makeRepository ./fixtures/git-repository;
  npmRepository = makeRepository ./fixtures/npm-repository;
  classicRepository = makeRepository ./fixtures/classic-repository;
  fakePrefetchGit = pkgs.writeShellScript "nix-prefetch-git" ''
    echo '{ "hash": "${lib.fakeHash}" }'
  '';
  # A repository as fetchgit returns it without `leaveDotGit`: its files,
  # without the .git directory.
  checkoutOf =
    repository:
    pkgs.runCommand "checkout" { } ''
      cp -r ${repository} "$out"
      chmod -R u+w "$out"
      rm -rf "$out/.git"
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
    printf 'plugins:\n  - path: %s\n    spec: "@nix-purifiers/plugin-yarn-berry-purifier"\n' ${plugin}/purifier.cjs > "$HOME/.yarnrc.yml"
    export YARN_ENABLE_TELEMETRY=0
    export YARN_GLOBAL_FOLDER="$TMPDIR/yarn-global"
  '';

  # Installs fixtures/app from a copy of its served downloads that `change`
  # alters, and passes when the install fails with `expected` in its
  # output.
  failedInstall =
    name: change: expected:
    pkgs.runCommand "${name}-check" { nativeBuildInputs = [ pkgs.yarn-berry ]; } ''
      ${yarnWithPlugin}
      cp -rL ${servedApp} served
      chmod -R u+w served
      ${change}
      export BERRY_PURIFIER_SERVE="$PWD/served"
      cp -r ${./fixtures/app} project
      chmod -R u+w project
      cd project
      if yarn install --immutable --mode=skip-build > "$TMPDIR/install.log" 2>&1; then
        echo "the install succeeded" >&2
        exit 1
      fi
      if ! grep -qF ${lib.escapeShellArg expected} "$TMPDIR/install.log"; then
        cat "$TMPDIR/install.log" >&2
        exit 1
      fi
      touch $out
    '';

  # The everyday loop of fixtures/app with no network: .yarn/purifier laid
  # out as `yarn-berry-purifier prefetch` leaves it, from the same
  # derivations, then `yarn install` and the build script through the
  # plugin, with no BERRY_PURIFIER_SERVE. `setup` runs in the project
  # first.
  offlineLoop =
    name: setup:
    pkgs.runCommand name { nativeBuildInputs = [ pkgs.yarn-berry ]; } ''
      ${yarnWithPlugin}
      cp -r ${./fixtures/app} project
      chmod -R u+w project
      cd project
      mkdir -p .yarn/purifier
      ln -s ${servedApp} .yarn/purifier/downloads
      printf '%s' "$(sha256sum ${./fixtures/app/yarn-berry-purifier.lock.json} | cut -d' ' -f1)" \
        > .yarn/purifier/downloads.stamp
      ${setup}
      yarn install --immutable
      yarn run build
      grep -q 'built by the build script (3 is odd: true)' dist/message.js
      touch $out
    '';
in
{
  # The package's command prints what its build script wrote, its dev
  # dependency stays out of the installed package, and its release holds
  # the built file.
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
        tar -xzOf ${app.release}/hello-berry.tgz package/dist/message.js \
          | grep -q 'built by the build script'
        touch $out
      '';

  # The project's `test` script passes in the sandbox.
  app-tests = app.tests;

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
      lock = sealed {
        inputsHash = yarnLockHash;
        yarn = release;
        downloads = [
          {
            path = "https/registry.yarnpkg.com/@esbuild%2flinux-x64/-/linux-x64-0.25.0.tgz";
            url = "https://registry.yarnpkg.com/@esbuild%2flinux-x64/-/linux-x64-0.25.0.tgz";
            hash = "sha512-9yl91rHw/cpwMCNytUDxwj2XjFpxML0y9HAOH9pNVQDpQrBxHy01Dx+vaMu0N1CKa/RzBD2hB4u//nfc+Sd3Cw==";
            systems = [ "x86_64-linux" ];
          }
          {
            path = "https/registry.yarnpkg.com/@esbuild%2flinux-arm64/-/linux-arm64-0.25.0.tgz";
            url = "https://registry.yarnpkg.com/@esbuild%2flinux-arm64/-/linux-arm64-0.25.0.tgz";
            hash = "sha512-9QAQjTWNDM/Vk2bgBl17yWuZxZNQIF0OUUuPZRKoDtqF2k4EtYbpyiG5/Dk7nqeK6kIJWPYldkOcBqjXjrUlmg==";
            systems = [ "aarch64-linux" ];
          }
        ];
      };
      urls =
        system:
        map (d: d.url) (
          builtins.filter (d: d ? systems) (purifier.entriesFor system (readLock lock yarnLockText))
        );
    in
    evalCheck "platform-filter" (
      urls "x86_64-linux"
      == [ "https://registry.yarnpkg.com/@esbuild%2flinux-x64/-/linux-x64-0.25.0.tgz" ]
      &&
        urls "aarch64-linux" == [
          "https://registry.yarnpkg.com/@esbuild%2flinux-arm64/-/linux-arm64-0.25.0.tgz"
        ]
    ) "the downloads for x86_64-linux and aarch64-linux are not the matching esbuild package";

  # A purifier lockfile written for another yarn.lock fails evaluation,
  # while the same lockfile reads for its own yarn.lock.
  conformance-stale = evalCheck "conformance-stale" (
    usable (sealed goodLock) yarnLockText && rejected (sealed goodLock) "# another yarn.lock\n"
  ) "a purifier lockfile for another yarn.lock evaluated";

  # A lockfile whose download hash was changed after it was written fails
  # evaluation, because its contentHash no longer matches.
  conformance-tampered =
    let
      lock = sealed goodLock;
      tampered = lock // {
        downloads = [
          (
            download
            // {
              hash = "sha512-9QAQjTWNDM/Vk2bgBl17yWuZxZNQIF0OUUuPZRKoDtqF2k4EtYbpyiG5/Dk7nqeK6kIJWPYldkOcBqjXjrUlmg==";
            }
          )
        ];
      };
    in
    evalCheck "conformance-tampered" (
      usable lock yarnLockText && rejected tampered yarnLockText
    ) "a purifier lockfile with a changed hash evaluated";

  # A project without its purifier lockfile is reported by readLock, and a
  # request the purifier lockfile has no download for fails the install;
  # both name the command to run. The yarn.lock of Yarn Berry, which names
  # the packages, is YAML, which Nix does not read, so a missing download
  # shows only when Yarn requests it.
  conformance-missing =
    if
      reported (
        yarn-berry-purifier.readLock {
          src = ./fixtures/app;
          lockFile = ./fixtures/app/missing.lock.json;
        }
      )
    then
      failedInstall "conformance-missing" ''
        rm "$(find served -name '*.tgz' | sort | head -1)"
      '' "is not in the purifier lockfile. Run `yarn-berry-purifier lock`"
    else
      throw "yarn-berry-purifier check conformance-missing: readLock reported no problem for a missing purifier lockfile";

  # readLock gives the lock in memory of the purifier contract, which the
  # purifier library's checkLock accepts: the project's packages as
  # outputs, and downloads that keep the systems that fetch them.
  read-lock =
    let
      lock = purifier.checkLock (yarn-berry-purifier.readLock { src = ./fixtures/app; });
    in
    evalCheck "read-lock" (
      lock.purifier == "yarn-berry-purifier"
      &&
        lock.outputs == {
          hello-berry = {
            version = "1.0.0";
            dir = "";
            bin.hello-berry = "bin/hello.js";
          };
        }
      && builtins.any (e: e ? systems) lock.entries
      && lock.problems == [ ]
    ) "readLock of fixtures/app gave another lock";

  # Malformed purifier lockfiles fail evaluation: one that holds no
  # object, one of another version, one without its contentHash, one with
  # a contentHash of other content, one without its inputsHash, and one
  # with a download entry without a hash.
  conformance-malformed = evalCheck "conformance-malformed" (
    usable (sealed goodLock) yarnLockText
    && rejected [ ] yarnLockText
    && rejected (sealed goodLock // { version = 2; }) yarnLockText
    && rejected (goodLock // { version = 1; }) yarnLockText
    && rejected (sealed goodLock // { contentHash = yarnLockHash; }) yarnLockText
    && rejected (sealed (removeAttrs goodLock [ "inputsHash" ])) yarnLockText
    && rejected (sealed (
      goodLock // { downloads = [ (removeAttrs download [ "hash" ]) ]; }
    )) yarnLockText
  ) "a malformed purifier lockfile evaluated";

  # A lock run of fixtures/app reproduces its committed purifier lockfile
  # byte for byte. The lock run needs the network, so the check is a
  # fixed-output build with an empty output. Nix builds a fixed-output
  # derivation once per name, so the name carries a digest of the plugin
  # and the fixture, and the check runs again when either changes.
  conformance-relock =
    let
      digest = builtins.hashString "sha256" (
        lib.concatMapStrings builtins.readFile [
          ../plugin/purifier.cjs
          ../plugin/foreign.cjs
          ./fixtures/app/package.json
          ./fixtures/app/yarn.lock
          ./fixtures/app/yarn-berry-purifier.lock.json
        ]
      );
    in
    pkgs.runCommand "conformance-relock-${builtins.substring 0 16 digest}"
      {
        nativeBuildInputs = [
          pkgs.yarn-berry
          pkgs.cacert
        ];
        outputHashMode = "flat";
        outputHashAlgo = "sha256";
        outputHash = builtins.hashString "sha256" "";
      }
      ''
        ${yarnWithPlugin}
        export NODE_EXTRA_CA_CERTS=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        cp -r ${./fixtures/app} project
        chmod -R u+w project
        cd project
        yarn purifier lock
        if ! cmp yarn-berry-purifier.lock.json ${./fixtures/app/yarn-berry-purifier.lock.json}; then
          diff ${./fixtures/app/yarn-berry-purifier.lock.json} yarn-berry-purifier.lock.json >&2
          exit 1
        fi
        touch $out
      '';

  # `yarn-berry-purifier update` moves kleur, which fixtures/update locks
  # at 4.0.0 within ^4.0.0, to a newer version in yarn.lock, and relocks
  # the purifier lockfile, so that readLock reports no problem with the
  # two. The update needs the network, so the check is a fixed-output
  # build with an empty output, whose name carries a digest of the plugin,
  # the lockfile reader and the fixture.
  conformance-update =
    let
      digest = builtins.hashString "sha256" (
        lib.concatMapStrings builtins.readFile [
          ../plugin/purifier.cjs
          ../nix/lib/lock.nix
          ../nix/lib/read-lock.nix
          ./fixtures/update/package.json
          ./fixtures/update/yarn.lock
          ./fixtures/update/yarn-berry-purifier.lock.json
        ]
      );
    in
    pkgs.runCommand "conformance-update-${builtins.substring 0 16 digest}"
      {
        nativeBuildInputs = [
          withOverlay.yarn-berry-purifier.yarn-berry-purifier
          pkgs.nix
          pkgs.cacert
        ];
        outputHashMode = "flat";
        outputHashAlgo = "sha256";
        outputHash = builtins.hashString "sha256" "";
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        export NODE_EXTRA_CA_CERTS=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        export YARN_ENABLE_TELEMETRY=0
        export NIX_CONFIG=$'experimental-features = nix-command\nstore = dummy://'
        cp -r ${./fixtures/update} project
        chmod -R u+w project
        cd project
        yarn-berry-purifier update --system x86_64-linux
        if grep -q '"kleur@npm:4.0.0"' yarn.lock; then
          echo "the update left kleur at 4.0.0" >&2
          exit 1
        fi
        grep -q '"\^4.0.0"' package.json
        problems="$(nix eval --impure --json --expr '
          (import ${../nix/lib}/read-lock.nix { lib = import ${pkgs.path}/lib; } {
            src = /. + builtins.getEnv "PWD";
          }).problems
        ')"
        if [ "$problems" != "[]" ]; then
          echo "the updated lockfiles have problems: $problems" >&2
          exit 1
        fi
        touch $out
      '';

  # The installed package of fixtures/app. CI builds it again with
  # `nix build --rebuild`, which fails when the second build differs.
  conformance-rebuild = app.packages.hello-berry;

  # After `yarn-berry-purifier prefetch`, the everyday loop of fixtures/app
  # runs in the sandbox, which has no network.
  conformance-offline = offlineLoop "conformance-offline" "";

  # The same loop with the purifier lockfile outside the project, as
  # `yarn-berry-purifier prefetch --lockfile` leaves it.
  offline-external = offlineLoop "offline-external" ''
    mv yarn-berry-purifier.lock.json "$TMPDIR/app.lock.json"
    printf '%s' "$TMPDIR/app.lock.json" > .yarn/purifier/lockfile
  '';

  # A project whose source holds no purifier lockfile builds from one kept
  # outside it, as a flake that packages a project it does not change
  # keeps it.
  conformance-external =
    let
      project = buildYarnBerryProject {
        src = builtins.path {
          name = "app-without-lockfile";
          path = ./fixtures/app;
          filter = path: _: baseNameOf path != "yarn-berry-purifier.lock.json";
        };
        lockFile = ./fixtures/app/yarn-berry-purifier.lock.json;
      };
    in
    pkgs.runCommand "conformance-external" { nativeBuildInputs = [ project.packages.hello-berry ]; } ''
      hello-berry | grep -q 'hello-berry: built by the build script (3 is odd: true)'
      touch $out
    '';

  # The hash a download entry records is the hash its fetch expects, so a
  # build fails when the file at the URL differs from the recorded one.
  locked-hash =
    let
      fetched = purifier.fetchEntry {
        inherit pkgs;
        fetchurl = args: args;
      } (removeAttrs download [ "systems" ] // { mirrors = [ ]; });
    in
    evalCheck "locked-hash" (
      fetched.hash == download.hash
    ) "the fetch of a download expects another hash than the locked one";

  # The install fails when a served file differs from the locked one: Yarn
  # compares each archive with the checksum in yarn.lock.
  tampered-file = failedInstall "tampered-file" ''
    set -- $(find served -name '*.tgz' | sort)
    cp "$2" "$1"
  '' "checksum";

  # The directory interactive use serves from holds every download the
  # build fetches, at its path. The Yarn release, whose path has no
  # directory, is fetched for the build's own Yarn and is not served.
  interactive = pkgs.runCommand "interactive-check" { } ''
    ${lib.concatMapStrings (f: "test -e ${servedApp}/${lib.escapeShellArg f.path}\n") (
      builtins.filter (f: f ? url && lib.hasInfix "/" f.path) app.fetches
    )}
    touch $out
  '';

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

  # `yarn-berry-purifier publish` builds the tarball nix/lib/publish.nix
  # names, which is the package's tarball in the release.
  publish-tarball =
    let
      tarball = import ../nix/lib/publish.nix {
        inherit purifier;
        pkgs = withOverlay;
        src = ./fixtures/app;
        package = "hello-berry";
      };
    in
    pkgs.runCommand "publish-tarball-check" { } ''
      cmp ${tarball}/package.tgz ${app.release}/hello-berry.tgz
      touch $out
    '';

  # `yarn-berry-purifier publish` uploads the tarball byte for byte,
  # through Yarn's own publish request. The registry is a local server.
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
        yarn purifier publish --tarball ${app.release}/hello-berry.tgz
        jq -r '._attachments[].data' "$TMPDIR/body" | base64 -d > "$TMPDIR/uploaded.tgz"
        cmp "$TMPDIR/uploaded.tgz" ${app.release}/hello-berry.tgz
        touch $out
      '';

  # The lock run of a project with a git dependency that Yarn clones. The
  # repository is the fixture repository, which git's insteadOf puts in
  # place of the dependency's URL, so the run needs no network;
  # nix-prefetch-git, which would fetch it, is replaced by a command that
  # prints a hash. The lockfile records the URL Yarn clones and the locked
  # commit, and `--lockfile` writes it outside the project. The check's
  # output holds the yarn.lock and purifier lockfile of the run, from which
  # fixtures/git was made.
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
        yarn purifier lock --system x86_64-linux --lockfile "$TMPDIR/written.lock.json"
        test ! -e yarn-berry-purifier.lock.json
        cp "$TMPDIR/written.lock.json" yarn-berry-purifier.lock.json
        jq -e '.repositories | length == 1' yarn-berry-purifier.lock.json
        jq -e '.repositories[0] | del(.git.commitObject) == {
          path: "git/55e425bf63e80624db0138ef7ff3ff32fe4c7ab5",
          git: {
            url: "https://git.example.invalid/git-dependency.git",
            rev: "55e425bf63e80624db0138ef7ff3ff32fe4c7ab5",
            submodules: false,
            leaveDotGit: true
          },
          hash: "${lib.fakeHash}",
          remote: "https://git.example.invalid/git-dependency.git"
        }' yarn-berry-purifier.lock.json
        # The commit object is the locked commit's own, and the commit has
        # no submodules.
        jq -e '.repositories[0].git.commitObject.gitlinks == []' yarn-berry-purifier.lock.json
        jq -r '.repositories[0].git.commitObject.object' yarn-berry-purifier.lock.json | base64 -d \
          | git hash-object -t commit --stdin | grep -qx 55e425bf63e80624db0138ef7ff3ff32fe4c7ab5
        mkdir -p "$out"
        cp yarn.lock yarn-berry-purifier.lock.json "$out"
      '';

  # The build of that project. Yarn clones the dependency in the sandbox
  # from the served repository, through the insteadOf settings of the
  # served directory, and packs it, which runs its prepack script.
  # `fetchers.fetchgit` returns the fixture repository in place of a clone
  # of the dependency's URL.
  git-build =
    let
      project = buildYarnBerryProject {
        src = ./fixtures/git;
        fetchers.fetchgit = _: checkoutOf gitRepository;
      };
    in
    pkgs.runCommand "git-build-check" { nativeBuildInputs = [ project.packages.uses-git-dependency ]; }
      ''
        uses-git-dependency | grep -qx 'cloned and packed'
        touch $out
      '';

  # Four git dependencies whose repositories Yarn packs with another
  # package manager, each with a prepare script that runs a devDependency:
  # one with a package-lock.json, which npm installs offline from its
  # cache; one with a Yarn Classic yarn.lock, which Yarn Classic installs
  # from its offline mirror after `yarn set version classic`; and one of
  # each that names its package manager in packageManager and has no
  # lockfile, which gets the lockfile the lock run resolved for it. The
  # lockfiles come from a lock run against the fixture repositories, and
  # `fetchers.fetchgit` returns those repositories in place of clones.
  foreign =
    let
      repositories = {
        npm-dependency = npmRepository;
        classic-dependency = classicRepository;
        npm-lockless-dependency = makeRepository ./fixtures/npm-lockless-repository;
        classic-lockless-dependency = makeRepository ./fixtures/classic-lockless-repository;
      };
      project = buildYarnBerryProject {
        src = ./fixtures/foreign;
        fetchers.fetchgit = args: checkoutOf repositories.${lib.removeSuffix ".git" (baseNameOf args.url)};
      };
    in
    pkgs.runCommand "foreign-check"
      { nativeBuildInputs = [ project.packages.uses-foreign-dependencies ]; }
      ''
        uses-foreign-dependencies > out.txt
        grep -qx 'npm prepared (3 is odd: true)' out.txt
        grep -qx 'classic prepared (3 is odd: true)' out.txt
        grep -qx 'npm resolved and prepared (3 is odd: true)' out.txt
        grep -qx 'classic resolved and prepared (3 is odd: true)' out.txt
        touch $out
      '';

  # The unit tests of the plugin, run against the plugin as it is built.
  unit = pkgs.runCommand "unit" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
    PLUGIN=${plugin} node --test ${./unit.test.cjs}
    touch $out
  '';

  # A real-world project, pinned: prettier on Yarn 4.18.1, the release its
  # .yarnrc.yml names, built by its own build script. The purifier
  # lockfile, real-world/prettier.lock.json, is the output of
  # `yarn-berry-purifier lock` for the pinned commit, kept outside the
  # source. builtins.fetchTarball fetches the source at evaluation time, so
  # the builder reads its package.json files without import from
  # derivation.
  prettier =
    let
      project = buildYarnBerryProject {
        src = builtins.fetchTarball {
          url = "https://github.com/prettier/prettier/archive/bed4edbb1cf2a9db4004215b0ce5707cdb02b5d9.tar.gz";
          sha256 = "sha256-Gm9jbi8E8AX2366olEPodeBwCJ42RRGnhKr4Wl9u2UM=";
        };
        lockFile = ./real-world/prettier.lock.json;
      };
    in
    pkgs.runCommand "prettier-check" { nativeBuildInputs = [ project.packages.prettier ]; } ''
      printf 'const  a  =  {b:1}\n' > input.js
      prettier input.js | grep -qx 'const a = { b: 1 };'
      touch $out
    '';

  # The wrapper and the command build.
  yarn = withOverlay.yarn-berry-purifier.yarn;
  yarn-berry-purifier = withOverlay.yarn-berry-purifier.yarn-berry-purifier;
}
