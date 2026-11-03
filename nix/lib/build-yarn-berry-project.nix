# SPDX-License-Identifier: MIT
#
# buildYarnBerryProject: sandboxed builds of a Yarn Berry (Yarn 3 and later)
# project, from its yarn.lock and the yarn-berry-purifier.lock.json that
# `yarn-berry-purifier lock` writes beside it. The project needs no Nix
# files of its own: the purifier lockfile names every file the install
# downloads, with its hash, and the package.json files name the project's
# own packages (the root and its workspaces).
#
# The file is a package for callPackage: the first argument set is what it
# takes by name from the scope `pkgs.yarn-berry-purifier`, which the flake's
# `overlays.default` adds to the package set, and the result is the
# builder. A package written for callPackage takes the scope by name:
#
#   { yarn-berry-purifier }:
#   (yarn-berry-purifier.buildYarnBerryProject { src = ./.; }).packages.my-app
#
# and `buildYarnBerryProject.override` replaces what the builder takes.
# The builder returns
#
#   packages.<name>   package <name> of the project, installed with its
#                     production dependencies under lib/node_modules, with
#                     its commands in bin/
#   tests             the project after `yarn install`, its build scripts
#                     and its `test` script, run in the sandbox
#   release           the project after `yarn install`, its build scripts
#                     and `yarn pack`: one tarball per package of the
#                     project, the files `yarn-berry-purifier publish`
#                     uploads
#   fetches           the entries of the purifier library that the build
#                     fetches on its system: the downloads, the git
#                     repositories and the Yarn release
{
  lib,
  stdenv,
  callPackage,
  # The packages that the purifier library's fetchEntry and tree take.
  runCommand,
  fetchurl,
  fetchgit,
  unzip,
  zstd,
  writeText,
  nodejs,
  nix,
  python3,
  node-gyp,
  git,
  autoPatchelfHook,
  runtimeShell,
  # The Yarn plugin of this scope, which the build loads into Yarn.
  plugin,
  # The `purifier` namespace of the shared library.
  purifier,
}:
{
  # The root of the Yarn project.
  src,
  # Replaces fetchers of the purifier library, such as `fetchurl` with one
  # that sends credentials to a company mirror. The purifier library's
  # fetchEntry and tree take it unchanged.
  fetchers ? { },
  dependencies ? purifier.lockedProjectInputs {
    inputs = (lib.importJSON lockFile).projectInputs or [ ];
    system = stdenv.hostPlatform.system;
  },
  # Yarn's lockfile. A yarn.lock given outside `src` replaces the one in
  # `src` during the build.
  yarnLock ? src + "/yarn.lock",
  # The purifier lockfile. A packaging flake can keep it outside `src`; it
  # then replaces any copy in `src` during the build.
  lockFile ? src + "/yarn-berry-purifier.lock.json",
  # The Node.js that runs Yarn and the project's scripts, and that the
  # packages' commands run on.
  node ? nodejs,
  # The workspaces to build, by package name, in the order their scripts
  # run, or null for every package of the project. When it is a list, the
  # install covers only these workspaces and their dependencies
  # (`yarn workspaces focus`), each build script runs in each of them that
  # defines it, and `packages` holds only them. A workspace whose
  # dependencies cannot install offline, such as a documentation site
  # whose sharp downloads libvips in its install script, stays out of the
  # build this way.
  workspaces ? null,
  # The package scripts that build the project, run in order before the
  # packages are packed. A script the root package defines runs at the
  # root; otherwise it runs in each workspace that defines it.
  buildScripts ? [ "build" ],
  # Tools the build scripts and the dependencies' install scripts need.
  # Python and node-gyp are there for native addons; setuptools gives the
  # older node-gyp releases that packages bundle the distutils module,
  # which Python 3.12 removed.
  nativeBuildInputs ? [
    (python3.withPackages (ps: [ ps.setuptools ]))
    node-gyp
  ],
  # Libraries native addons link against.
  buildInputs ? [ ],
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out installed
  # dependencies, Yarn's cache and install state, version control and Nix
  # result links.
  srcFilter ? null,
}:
let
  inherit (stdenv.hostPlatform) system;

  # The lock in memory of the purifier contract, which checkLock fails
  # evaluation on when the lockfiles cannot be used.
  rawLock = import ./lock.nix { inherit lib lockFile yarnLock; };
  supplied =
    if dependencies == [ ] || rawLock.problems != [ ] then
      {
        paths = [ ];
        remotes = [ ];
      }
    else
      let
        queryYarn =
          if rawLock.release == null then
            "${filteredSrc}/${rawLock.yarn.path}"
          else
            purifier.fetchEntry fetchArgs rawLock.release;
        result =
          runCommand "yarn-berry-supplied-requests.json"
            {
              spec = builtins.toJSON {
                names = inputSelection.names;
                versions = inputSelection.versions;
              };
              passAsFile = [ "spec" ];
            }
            ''
              cp -r ${filteredSrc} project
              chmod -R u+w project
              cp --no-preserve=mode ${yarnLock} project/yarn.lock
              export HOME="$TMPDIR/home" BERRY_PURIFIER_INPUT_VIEWS='[]'
              export YARN_ENABLE_TELEMETRY=0 YARN_ENABLE_GLOBAL_CACHE=false
              mkdir -p "$HOME"
              cat > "$HOME/.yarnrc.yml" <<'EOF'
              plugins:
                - path: ${plugin}/purifier.cjs
                  spec: "@nix-purifiers/plugin-yarn-berry-purifier"
              EOF
              cd project
              ${lib.getExe node} ${queryYarn} purifier query-inputs --provided "$specPath" --output "$out"
            '';
      in
      lib.importJSON result;
  read = import ./read-lock.nix { inherit lib; } {
    inherit src yarnLock lockFile;
    excludedPaths = supplied.paths;
    excludedRemotes = supplied.remotes;
  };
  checked = purifier.checkLock read;
  # The rest of the purifier lockfile, read only after the check.
  lock = builtins.seq checked (
    import ./lock.nix {
      inherit lib lockFile yarnLock;
      excludedPaths = supplied.paths;
      excludedRemotes = supplied.remotes;
    }
  );

  # The entries this system fetches. A lockfile whose lock runs left out
  # this system has downloads, but none for it.
  entries =
    let
      forSystem = purifier.entriesFor system read;
      hasDownloads = builtins.any (e: e ? systems);
    in
    if hasDownloads checked.entries && !(hasDownloads forSystem) then
      throw "yarn-berry-purifier: ${toString lockFile} covers no download for ${system}. Run `yarn-berry-purifier lock --system ${system}`."
    else
      forSystem;

  fetchArgs = {
    inherit
      fetchurl
      fetchgit
      runCommand
      unzip
      zstd
      python3
      writeText
      ;
  }
  // fetchers;

  allPackages = import ./workspaces.nix { inherit lib src; };
  ownPackageSet =
    if workspaces == null then
      allPackages
    else
      lib.genAttrs workspaces (
        name:
        allPackages.${name}
          or (throw "yarn-berry-purifier: the project has no workspace named ${name}; its packages are ${lib.concatStringsSep ", " (builtins.attrNames allPackages)}.")
      );
  ownPackages =
    if workspaces == null then
      builtins.attrValues ownPackageSet
    else
      map (name: ownPackageSet.${name}) workspaces;

  # The install of every package, or of the listed workspaces, with or
  # without their development dependencies.
  install =
    production:
    let
      targets = if workspaces == null then "--all" else lib.escapeShellArgs workspaces;
    in
    if production then
      "yarn workspaces focus --production ${targets}"
    else if workspaces == null then
      "yarn install --immutable"
    else
      "yarn workspaces focus ${targets}";

  defaultSrcFilter =
    path: type:
    let
      name = baseNameOf path;
      parent = baseNameOf (dirOf path);
    in
    !(
      (type == "directory" && name == "node_modules")
      || name == ".git"
      || lib.hasPrefix "result" name
      || lib.hasPrefix ".pnp." name
      || name == ".yarn-berry-purifier"
      || (
        parent == ".yarn"
        && lib.elem name [
          "unplugged"
          "install-state.gz"
          "build-state.yml"
        ]
      )
    );

  filteredSrc = builtins.path {
    path = src;
    name = "yarn-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  served = callPackage ./served.nix {
    inherit purifier fetchers entries;
    inherit (lock) npmLocks externals;
  };

  steps = import ./yarn-steps.nix {
    inherit
      lib
      node
      plugin
      ;
    dependencies = served;
    inherit runtimeShell;
    yarnJs =
      if lock.release == null then "./${lock.yarn.path}" else purifier.fetchEntry fetchArgs lock.release;
  };

  inputSelection = purifier.npmInputSelection { inherit dependencies; };
  setup = steps.setup + ''
    export BERRY_PURIFIER_INPUT_VIEWS=${lib.escapeShellArg (builtins.toJSON inputSelection.views)}
    ${lib.optionalString (dependencies != [ ]) ''
      YARN_ENABLE_IMMUTABLE_INSTALLS=false yarn install --mode=skip-build
    ''}
  '';

  # The lockfiles given to the builder replace those in the project, so
  # Yarn and the plugin read the given ones.
  useLockfiles = ''
    cp ${yarnLock} yarn.lock
    cp ${lockFile} yarn-berry-purifier.lock.json
    chmod u+w yarn.lock yarn-berry-purifier.lock.json
  '';

  # Prebuilt Linux binaries in packages, such as turbo's, get their dynamic
  # loader and libraries from the store, and scripts get their
  # interpreters patched, because the sandbox has no /usr/bin/env. An
  # install with --mode=skip-build lays the packages out without running
  # their build scripts; the files are patched in node_modules and
  # .yarn/unplugged, and a second install runs the build scripts.
  binaryPatching = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  binaryLibraries = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];
  patchInstalled = ''
    patchInstalled() {
      local dirs=()
      while IFS= read -r -d "" dir; do
        dirs+=("$dir")
      done < <(find . \( -name node_modules -o -path ./.yarn/unplugged \) -type d -prune -print0)
      if [ ''${#dirs[@]} -gt 0 ]; then
        patchShebangs "''${dirs[@]}" > /dev/null
        if declare -F autoPatchelf > /dev/null; then
          autoPatchelf "''${dirs[@]}"
        fi
      fi
    }
  '';

  # The file name of a package's tarball in `release`.
  tarballName = p: (builtins.replaceStrings [ "@" "/" ] [ "" "__" ] p.name) + ".tgz";

  # Runs package script $1 at the root when the root defines it and no
  # workspaces are listed, and in every workspace that defines it
  # otherwise.
  runScript = ''
    runScript() {
      if ${
        if workspaces == null then "true" else "false"
      } && node -e 'process.exit(require("./package.json").scripts?.[process.argv[1]] ? 0 : 1)' "$1"; then
        yarn run "$1"
      else
        ${lib.concatMapStrings (p: ''
          if node -e 'process.exit(require(process.argv[2] + "/package.json").scripts?.[process.argv[1]] ? 0 : 1)' "$1" ./${lib.escapeShellArg p.dir}; then
            yarn workspace ${lib.escapeShellArg p.name} run "$1"
          fi
        '') (builtins.filter (p: p.dir != "") ownPackages)}
        :
      fi
    }
  '';

  # The project after `yarn install` and its build scripts, followed by
  # `scripts`, and installed by `installPhase`.
  projectBuild =
    {
      name,
      scripts,
      installPhase,
      nodeModules ? false,
    }:
    stdenv.mkDerivation {
      inherit name installPhase;
      src = filteredSrc;
      nativeBuildInputs = [
        node
        git
      ]
      ++ nativeBuildInputs
      ++ binaryPatching;
      buildInputs = buildInputs ++ binaryLibraries;
      autoPatchelfIgnoreMissingDeps = [ "*" ];
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        ${useLockfiles}
        ${lib.optionalString nodeModules "export YARN_NODE_LINKER=node-modules"}
        ${setup}
        ${patchInstalled}
        YARN_ENABLE_SCRIPTS=0 ${install false}
        patchInstalled
        ${install false}
        ${runScript}
        for script in ${lib.escapeShellArgs (buildScripts ++ scripts)}; do
          runScript "$script"
        done
        runHook postBuild
      '';
      dontFixup = true;
    };

  # `yarn pack` runs the packages' prepack and postpack scripts, as
  # `yarn npm publish` does. The tarballs are what Yarn publishes, byte
  # for byte.
  rawRelease = projectBuild {
    name = "yarn-project-build";
    scripts = [ ];
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      ${lib.concatMapStrings (p: ''
        yarn ${
          lib.optionalString (p.dir != "") "workspace ${lib.escapeShellArg p.name}"
        } pack --out "$out"/${lib.escapeShellArg (tarballName p)}
      '') ownPackages}
      runHook postInstall
    '';
  };

  tests = projectBuild {
    name = "yarn-project-tests";
    scripts = [ "test" ];
    installPhase = ''
      runHook preInstall
      touch "$out"
      runHook postInstall
    '';
  };

  productionModules = stdenv.mkDerivation {
    name = "yarn-project-production-modules";
    src = filteredSrc;
    nativeBuildInputs = [
      node
      git
    ]
    ++ nativeBuildInputs
    ++ binaryPatching;
    buildInputs = buildInputs ++ binaryLibraries;
    autoPatchelfIgnoreMissingDeps = [ "*" ];
    dontConfigure = true;
    # The installed packages lay their dependencies out in node_modules,
    # where Node.js finds them without Yarn's Plug'n'Play loader, so this
    # install uses the node-modules linker whatever the project uses.
    buildPhase = ''
      runHook preBuild
      ${useLockfiles}
      ${setup}
      ${patchInstalled}
      export YARN_NODE_LINKER=node-modules
      YARN_ENABLE_SCRIPTS=0 ${install true}
      patchInstalled
      ${install true}
      # A `link:` or `portal:` dependency is a symlink into the project,
      # which the installed packages do not contain, so it becomes a copy of
      # its target.
      find . -path '*node_modules/*' -not -path '*/.bin/*' -type l -print0 \
        | while IFS= read -r -d "" link; do
            target="$(readlink -f "$link")"
            rm "$link"
            cp -r "$target" "$link"
          done
      runHook postBuild
    '';
    # Every node_modules directory of the tree, at its place: the one at
    # the root, and those Yarn put inside workspaces for versions that could
    # not be hoisted.
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      find . -name node_modules -type d -prune -print0 | while IFS= read -r -d "" dir; do
        mkdir -p "$out/$(dirname "$dir")"
        cp -a "$dir" "$out/$dir"
      done
      runHook postInstall
    '';
    dontFixup = true;
  };

  # Package p installed the way a global install lays out a package:
  # lib/node_modules/<name> holds the package's files, and its production
  # dependencies lie beside it, where Node.js resolves them. The project's
  # own packages lie there as installed copies too, so a workspace that
  # depends on another finds it.
  mkPackage =
    p:
    stdenv.mkDerivation {
      pname = builtins.replaceStrings [ "@" "/" ] [ "" "-" ] p.name;
      inherit (p) version;
      dontUnpack = true;
      dontConfigure = true;
      dontBuild = true;
      # The commands' interpreter is this Node.js.
      buildInputs = [ node ];
      installPhase = ''
        runHook preInstall
        modules="$out/lib/node_modules"
        mkdir -p "$modules"
        if [ -d ${productionModules}/node_modules ]; then
          cp -a ${productionModules}/node_modules/. "$modules/"
          chmod -R u+w "$modules"
          rm -rf "$modules/.bin" "$modules/.yarn-state.yml"
        fi
        ${lib.concatMapStrings (o: ''
          rm -rf "$modules"/${lib.escapeShellArg o.name}
          mkdir -p "$modules"/${lib.escapeShellArg o.name}
          tar -xzf ${release}/${lib.escapeShellArg (tarballName o)} --strip-components=1 \
            -C "$modules"/${lib.escapeShellArg o.name}
          ${lib.optionalString (o.dir != "") ''
            if [ -d ${productionModules}/${lib.escapeShellArg o.dir}/node_modules ]; then
              cp -a ${productionModules}/${lib.escapeShellArg o.dir}/node_modules \
                "$modules"/${lib.escapeShellArg o.name}/node_modules
            fi
          ''}
        '') ownPackages}
        chmod -R u+w "$modules"
        ${lib.optionalString (p.bin != { }) ''mkdir -p "$out/bin"''}
        ${lib.concatStrings (
          lib.mapAttrsToList (command: file: ''
            target="$modules"/${lib.escapeShellArg p.name}/${lib.escapeShellArg file}
            chmod +x "$target"
            ln -s "$target" "$out/bin"/${lib.escapeShellArg command}
          '') p.bin
        )}
        runHook postInstall
      '';
      passthru = {
        inherit (p) name dir;
      };
      meta = lib.optionalAttrs (p.bin != { }) {
        mainProgram = builtins.head (builtins.attrNames p.bin);
      };
    };
  capture = projectBuild {
    name = "yarn-berry-runtime-graph";
    scripts = [ ];
    nodeModules = true;
    installPhase = ''
      export NPM_PURIFIER_NPM_MODULES=${node}/lib/node_modules/npm/node_modules
      export NPM_PROJECTION_NIX=${nix}/bin/nix
      node ${purifier.npmCaptureTool} "$PWD" ${rawRelease} "$out" ${
        writeText "yarn-berry-own-packages.json" (
          builtins.toJSON (
            map (p: {
              inherit (p) name dir;
              archive = "${rawRelease}/${tarballName p}";
            }) ownPackages
          )
        )
      }
    '';
  };
  projectionFor =
    roots:
    purifier.npmProjections {
      graph = "${capture}/graph.json";
      archives = "${capture}/archives";
      producer = rawRelease;
      inherit
        roots
        dependencies
        runCommand
        python3
        ;
    };
  projections = projectionFor null;
  release = rawRelease.overrideAttrs (previous: {
    passthru = (previous.passthru or { }) // {
      inherit projections;
    };
  });
in
{
  packages = lib.mapAttrs (
    name: p:
    lib.extendDerivation true {
      projections = projectionFor [ name ];
    } (mkPackage p)
  ) ownPackageSet;
  inherit tests release projections;
  fetches = checked.entries;
}
