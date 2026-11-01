# SPDX-License-Identifier: MIT
#
# buildYarnBerryProject: sandboxed builds of a Yarn Berry (Yarn 3 and later)
# project, from its yarn.lock and the yarn-berry-purifier.lock.json that
# `yarn purifier lock` writes beside it. The project needs no Nix files of
# its own: the purifier lockfile names every file the install downloads,
# with its hash, and the package.json files name the project's own packages
# (the root and its workspaces).
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# yarn-berry-purifier overlay (`overlays.default`) adds it to the package
# set as `buildYarnBerryProject`, so a package written for callPackage
# takes it like any other dependency:
#
#   { buildYarnBerryProject }:
#   (buildYarnBerryProject { src = ./.; }).packages.my-app
#
# and `buildYarnBerryProject.override` replaces what it takes from the
# set. The builder returns
#
#   dependencies      the locked downloads for the build's system
#   build             the project after `yarn install`, its build scripts
#                     and `yarn pack`: one tarball per package of the
#                     project
#   productionModules the production dependencies, installed by
#                     `yarn workspaces focus --production` with the
#                     node-modules linker
#   packages.<name>   package <name> of the project, installed with its
#                     production dependencies under lib/node_modules, with
#                     its commands in bin/; its `tarball` output holds
#                     package.tgz, the file `yarn npm publish` uploads
{
  lib,
  stdenv,
  callPackage,
  fetchurl,
  nodejs,
  python3,
  node-gyp,
  autoPatchelfHook,
  pkgs,
}:
{
  # The root of the Yarn project.
  src,
  # The lockfile Yarn writes at the project root.
  yarnLockFile ? src + "/yarn.lock",
  # The purifier lockfile.
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
  # Runs the `test` script the same way, after the build scripts.
  doCheck ? false,
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
  # Replaces the fetcher of the locked downloads.
  fetchurl ? null,
  # Replaces the fetcher of the git repositories Yarn clones.
  fetchgit ? null,
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out installed
  # dependencies, Yarn's cache and install state, version control and Nix
  # result links.
  srcFilter ? null,
}@args:
let
  lock = import ./lock.nix {
    inherit lib lockFile yarnLockFile;
    inherit (stdenv.hostPlatform) system;
  };

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
      || (
        parent == ".yarn"
        && lib.elem name [
          "unplugged"
          "install-state.gz"
          "build-state.yml"
          "purifier"
        ]
      )
    );

  filteredSrc = builtins.path {
    path = src;
    name = "yarn-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  dependencies = callPackage ./served.nix (
    {
      inherit (lock)
        downloads
        texts
        npmLocks
        externals
        repositories
        ;
    }
    // lib.optionalAttrs (args.fetchurl or null != null) { inherit (args) fetchurl; }
    // lib.optionalAttrs (args.fetchgit or null != null) { inherit (args) fetchgit; }
  );

  plugin = pkgs.yarn-berry-purifier.plugin or (callPackage ../../pkgs/plugin { });

  steps = import ./yarn-steps.nix {
    inherit
      lib
      node
      plugin
      dependencies
      ;
    fetchurl = pkgs.fetchurl;
    inherit (pkgs) runtimeShell;
    yarnRelease = lock.yarn;
  };

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

  # The file name of a package's tarball in `build`.
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

  build = stdenv.mkDerivation {
    name = "yarn-project-build";
    src = filteredSrc;
    nativeBuildInputs = [
      node
      pkgs.git
    ]
    ++ nativeBuildInputs
    ++ binaryPatching;
    buildInputs = buildInputs ++ binaryLibraries;
    autoPatchelfIgnoreMissingDeps = [ "*" ];
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      ${steps.setup}
      ${patchInstalled}
      YARN_ENABLE_SCRIPTS=0 ${install false}
      patchInstalled
      ${install false}
      ${runScript}
      for script in ${lib.escapeShellArgs buildScripts}; do
        runScript "$script"
      done
      ${lib.optionalString doCheck "runScript test"}
      runHook postBuild
    '';
    # `yarn pack` runs the packages' prepack and postpack scripts, as
    # `yarn npm publish` does.
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
    # The tarballs are what Yarn publishes, byte for byte.
    dontFixup = true;
  };

  productionModules = stdenv.mkDerivation {
    name = "yarn-project-production-modules";
    src = filteredSrc;
    nativeBuildInputs = [
      node
      pkgs.git
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
      ${steps.setup}
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
      outputs = [
        "out"
        "tarball"
      ];
      dontUnpack = true;
      dontConfigure = true;
      dontBuild = true;
      # The commands' interpreter is this Node.js.
      buildInputs = [ node ];
      installPhase = ''
        runHook preInstall
        modules="$out/lib/node_modules"
        mkdir -p "$modules" "$tarball"
        cp ${build}/${lib.escapeShellArg (tarballName p)} "$tarball/package.tgz"
        if [ -d ${productionModules}/node_modules ]; then
          cp -a ${productionModules}/node_modules/. "$modules/"
          chmod -R u+w "$modules"
          rm -rf "$modules/.bin" "$modules/.yarn-state.yml"
        fi
        ${lib.concatMapStrings (o: ''
          rm -rf "$modules"/${lib.escapeShellArg o.name}
          mkdir -p "$modules"/${lib.escapeShellArg o.name}
          tar -xzf ${build}/${lib.escapeShellArg (tarballName o)} --strip-components=1 \
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
in
{
  inherit dependencies build productionModules;
  packages = lib.mapAttrs (_: mkPackage) ownPackageSet;
}
