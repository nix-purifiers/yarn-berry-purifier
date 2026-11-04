# yarn-berry-purifier

yarn-berry-purifier keeps Yarn Berry's development workflow on locked,
Nix-resolved dependencies. Use the normal build and test commands in your
working tree; building the project itself in the Nix sandbox is an
optional next step.

## Quickstart

From the project root:

```zsh
nix shell 'github:nix-purifiers/yarn-berry-purifier#toolchain'
yarn-berry-purifier lock
yarn install
yarn run build
yarn test
```

Commit the lockfiles that the lock command writes, including the build
tool's own lockfile when it has one. Keep using the project's usual build,
test and editor commands with this setup. Nix provides the locked
dependencies; the development commands above run outside the Nix sandbox.
No project Nix files are needed for this workflow.

Sandboxed builds of the whole project are an optional
[next step](#building-the-project-with-nix).

The shell provides the `yarn` wrapper. Use it for the locked
development workflow. With no purifier lockfile, it warns on standard
error and runs the ordinary tool with impure resolution.

For persistent use, add these packages through your usual Nix configuration.


## Development loop

The development loop is Yarn's own commands, run through the flake's `yarn`
wrapper, which loads the plugin from a temporary home directory's
`.yarnrc.yml`. `nix shell 'github:nix-purifiers/yarn-berry-purifier#toolchain'`
gives a shell with that `yarn`, the `yarn-berry-purifier` command and
Node.js.

In a project with a purifier lockfile, `yarn install` installs from the
locked downloads, which Nix builds into the `.yarn-berry-purifier`
directory beside the purifier lockfile. The scripts of the project run as
usual with `yarn run`. The `.yarn-berry-purifier` directory belongs in
`.gitignore`.

A change to the dependencies goes through Yarn with the plugin's serving
turned off, then a new lock:

```zsh
BERRY_PURIFIER=0 yarn add left-pad
yarn-berry-purifier lock
```

`yarn-berry-purifier lock` keeps Yarn's resolution as `yarn.lock` holds
it, and writes a `yarn.lock` only for a project that has none, by running
`yarn install` without build scripts. `yarn-berry-purifier update` updates both lockfiles in one run: it runs
`yarn up --recursive` for the packages it names, or for every package when
it names none, which resolves them again to the newest versions their
ranges in `package.json` allow and leaves the ranges as they are, and then
relocks the purifier lockfile against the new `yarn.lock`. It takes
`--lockfile` and `--system` as `lock` does.

```zsh
yarn-berry-purifier update typescript
```

The lock run copies the project into `.yarn-berry-purifier/lock-run` at the
project root and installs it there once for each Nix system it covers, which are
x86_64-linux, aarch64-linux, x86_64-darwin and aarch64-darwin by default,
with `supportedArchitectures` set to that system. Each download records the
systems that fetch it, so a build fetches only the per-platform packages of
its own system. The lockfile also records the Yarn release: the one that
`.yarnrc.yml` names in `yarnPath`, or otherwise the release the command
runs in, from repo.yarnpkg.com. `--system` restricts the lock run to the
systems it names. A relock of an unchanged project writes the same
lockfile byte for byte.

`yarn-berry-purifier publish`, run in a workspace, publishes the tarball
that the sandboxed build packs for it, with the registry, credentials and
options that `yarn npm publish` uses. `--tarball <file>` publishes a
tarball that is already built.

## Published plugin

To load the plugin into an existing Yarn Berry installation:

```zsh
site=https://nix-purifiers.github.io
yarn plugin import \
  "$site/yarn-berry-purifier/plugins/purifier.cjs"
```

[Versioned plugins](https://nix-purifiers.github.io/yarn-berry-purifier/plugins/) are attached to each
[release](https://github.com/nix-purifiers/yarn-berry-purifier/releases).
The published plugin warns that it was resolved impurely; the Quickstart
wrapper provides pure plugin resolution.

## Dependencies from other purified projects

```zsh
nix shell 'github:nix-purifiers/yarn-berry-purifier#toolchain'
yarn-berry-purifier lock \
  --input 'github:example/library#library'
yarn install --immutable
yarn test
```

The producer can use Yarn Berry, Yarn Classic, Bun, npm or pnpm. Yarn's
dependency hook binds requests to the Nix-supplied identities, including
transitive dependencies, without rewriting package manifests. `projectInputs`
pins the Nix sources; supplied artifacts have no download entries.

The builder accepts producer outputs through `dependencies = [ library ];`
and uses recorded `projectInputs` by default. It exports `projections.npm`;
individual `packages.<name>` and `release` also expose native repositories.

For a composed project, `yarn-berry-purifier publish` publishes namespaced
archives with exact dependency requirements and the `nix` tag. Ordinary
package managers can consume the result. A published dependency is reused
only when its integrity matches the Nix input.

## Building the project with Nix

Once the native development workflow is working, you can also build and
test the whole project in the Nix sandbox. For this step, keep a flake or
another Nix build definition in the project's repository, or maintain an
external packaging repository that points at its sources and lockfiles.
The builder consumes the same lockfiles as the development workflow.

A flake is optional and can live in the project or in another repository:

```nix
{
  inputs.yarn-berry-purifier.url =
    "github:nix-purifiers/yarn-berry-purifier";
  inputs.nixpkgs.follows =
    "yarn-berry-purifier/nixpkgs";

  outputs =
    { nixpkgs, yarn-berry-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          yarn-berry-purifier.overlays.default
        ];
      };
      project =
        pkgs.yarn-berry-purifier.buildYarnBerryProject
          {
            src = ./.;
          };
    in
    {
      packages.${system}.my-app =
        project.packages.my-app;
      checks.${system}.tests = project.tests;
    };
}
```

`yarn-berry-purifier.overrideScope` replaces what everything in the scope
shares, and `buildYarnBerryProject.override` replaces the packages that
the builder takes by name, such as `nodejs`.

`buildYarnBerryProject` returns these attributes:

- `packages.<name>` is package `<name>` of the project, installed with its
  production dependencies under `lib/node_modules`, with its commands in
  `bin/`. The names come from the `package.json` files: the root, and the
  workspaces that the root's `workspaces` globs name.
- `tests` runs the project's `test` script in the sandbox, after the
  install and the build scripts.
- `release` holds one tarball per package, as `yarn pack` writes it: the
  files that `yarn-berry-purifier publish` uploads.
- `fetches` lists the entries of the
  [purifier](https://github.com/nix-purifiers/purifier) library that the
  build fetches on its system, for tools that read a software bill of
  materials, licenses or vulnerabilities.

`lib.yarn-berry-purifier.readLock { src, lockFile, yarnLock }` reads the
lockfiles into the lock in memory of the purifier contract, the shape that
every purifier gives. Its `entries` are the purifier library's download
entries, each download with the `systems` whose lock runs fetched it; its
`outputs` are the project's packages by name, with their version,
directory and commands; and its `problems` list why the lockfiles cannot be
used, each naming the command that fixes it. A tool that reads every
purifier, such as a generator of software bills of materials, calls it,
and the builder checks it with the purifier library's `checkLock`.

`nix/lib/build-yarn-berry-project.nix` documents the arguments. Besides
`src`, they include `fetchers` (replaces fetchers of the purifier library,
such as `fetchurl` for a company mirror or credentials), `lockFile`,
`yarnLock`, `workspaces` (builds only the listed workspaces),
`buildScripts`, `node`, `nativeBuildInputs` and `buildInputs`.

A build can also keep its lockfiles outside the repository, which is an
option for packaging a project that one does not change. The flake that
calls the builder keeps the purifier lockfile beside itself and passes it
as `lockFile`. It can also keep its own copy of `yarn.lock` and pass it as
`yarnLock`, which the build then uses in place of the copy in `src`. Every
command takes the purifier lockfile from `--lockfile <path>`, else from the
environment variable `YARN_BERRY_PURIFIER_LOCKFILE`, else from
`yarn-berry-purifier.lock.json` next to `yarn.lock`. It takes `yarn.lock`
from `--tool-lockfile <path>`, else from `YARN_BERRY_PURIFIER_TOOL_LOCKFILE`,
else from the project. A flag wins over its variable, and a variable over
the default place. With a tool lockfile, `lock` and `update` write the
`yarn.lock` there and leave the project's own copy as it is, starting from
that copy when the tool lockfile does not exist yet. The plugin accepts the
variables as the Yarn settings `berryPurifierLockfile` and
`berryPurifierToolLockfile`; without the plugin, Yarn rejects any `YARN_`
variable that it does not know.

```zsh
yarn-berry-purifier lock --lockfile \
  ../packaging/my-app.lock.json --tool-lockfile \
  ../packaging/my-app.yarn.lock
```

The dev shell of the flake that calls the builder can set the variables to
the paths it passes as `lockFile` and `yarnLock`, so that a developer in
that shell runs the commands, and the `yarn` wrapper, with no flag:

```nix
devShells.${system}.default = pkgs.mkShell {
  packages = [
    yarn-berry-purifier.packages.${system}.yarn
  ];
  YARN_BERRY_PURIFIER_LOCKFILE =
    toString ./my-app.lock.json;
  YARN_BERRY_PURIFIER_TOOL_LOCKFILE =
    toString ./my-app.yarn.lock;
};

```

### Graph helper runtime

The builder's `node` selects the project runtime. `captureNode` selects the
modern Node/npm tooling that inspects the installed graph, and defaults to
nixpkgs' Node. The graph records the target's version, ABI and platform separately
from the helper's runtime. Selecting an older `node` does not by itself establish
that the project's locked Yarn release and plugin APIs can run on it; those
native tool/runtime combinations need their own regression points.

### One-off builds without a project Nix file

For an ad hoc build, the builder can also be evaluated directly from the
project root. Replace the example package name with one from your project:

```zsh
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/yarn-berry-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.yarn-berry-purifier.buildYarnBerryProject { src = ./.; })
.packages.my-app'
```

This uses the purifier's pinned nixpkgs, matching the lock command above.
To build with ambient `<nixpkgs>` from your Nix search path instead,
replace `import purifier.inputs.nixpkgs` with `import <nixpkgs>`.
Both forms need no Nix files in your project. The build tool and language
versions must match the lockfile; with ambient nixpkgs, lock with the
purifier from that package set or pass a compatible toolchain to the builder.

## Working offline

`yarn-berry-purifier prefetch` realizes in the Nix store what the
development loop needs for the current system, with garbage-collector
roots in the `.yarn-berry-purifier` directory beside the purifier
lockfile: the locked downloads, the Yarn release the lockfile names, and
the Node.js and Yarn that the command runs on. Afterwards `yarn install`
and the scripts of the project work with the network cut off.

```zsh
yarn-berry-purifier prefetch
```

A purifier lockfile at `<dir>/yarn-berry-purifier.lock.json` gets its roots
in `<dir>/.yarn-berry-purifier/`, and the same holds for any other file
name, so one purifier lockfile belongs in each directory. For the default
place, `<dir>` is the project root. For a purifier lockfile outside the
project, the roots lie beside it. The plugin finds the roots from the
lockfile path in the same way, so a developer who prefetched with
`--lockfile <path>` runs the development loop with
`YARN_BERRY_PURIFIER_LOCKFILE=<path>` set, which the dev shell of the
packaging flake does for them.

## Editor

JavaScript editors take their tools from the dependencies that Yarn
installs in the project: TypeScript's language server comes from the
`typescript` package, and ESLint and Prettier come from their own
packages. After `yarn-berry-purifier prefetch` and `yarn install`, those
tools are in place and work offline. A project that uses Plug'n'Play needs
Yarn's editor SDK, which `yarn dlx @yarnpkg/sdks` installs; `@yarnpkg/sdks`
then has to be a dev dependency, so that the purifier lockfile records it.

## Troubleshooting

Every error names the command that fixes it.

- A build or `yarn install` after a change to `yarn.lock` reports that the
  purifier lockfile "was written for another yarn.lock". Run
  `yarn-berry-purifier lock`.
- A purifier lockfile that is not valid JSON, such as one with a merge
  conflict in it, fails with "<file> is not valid JSON. Run
  `yarn-berry-purifier lock`." The commands `prefetch` and `publish`, and
  `yarn install` through the plugin, check the file before Nix reads it,
  and `readLock` fails evaluation with the same message, because Nix cannot
  catch a parse error. Run `yarn-berry-purifier lock`, which rewrites the
  file.
- A lockfile that does not exist at the place `--lockfile`, the variable or
  the default names fails with "<file> does not exist". Run
  `yarn-berry-purifier lock`.
- A Yarn command that requests a file the lockfile lacks, such as
  `yarn add`, reports that the file "is not in the purifier lockfile". Run
  the Yarn command with `BERRY_PURIFIER=0`, then `yarn-berry-purifier lock`.
  A missing download shows up this way, when Yarn requests the file, and
  not when Nix reads the lock: `yarn.lock` is YAML, which Nix cannot read,
  so `readLock` reports a missing, stale or damaged purifier lockfile but
  not a missing entry.
- A lockfile edited by hand or by a merge "was changed after it was
  written; its contentHash does not match". The lockfile records the
  SHA-256 of its own content. Run `yarn-berry-purifier lock` instead of
  editing it.
- A lockfile from another release, or a damaged one, "has version N", "holds
  no JSON object" or "has a malformed download entry". Run
  `yarn-berry-purifier lock`.
- A build on a system that the lock run left out reports that the lockfile
  "covers no download for" that system. Run
  `yarn-berry-purifier lock --system <system>`, or `yarn-berry-purifier lock`
  for every system.
- `yarn-berry-purifier update` stops with "yarn up --recursive ... failed"
  when Yarn cannot resolve the packages, such as for a name no dependency
  matches; Yarn's own message above it says why, and both lockfiles stay as
  they were. When the relock after it fails, `yarn.lock` already holds the
  new resolution; run `yarn-berry-purifier lock` once the cause is fixed.
- A file whose content differs from the locked hash fails its fixed-output
  fetch in Nix, and Yarn's own checksum check fails an install from a
  changed file.
- A user behind a proxy sets it for Yarn, which reads the setting
  `httpsProxy` in `.yarnrc.yml` or the variable `YARN_HTTPS_PROXY` and
  ignores `HTTPS_PROXY`. The commands `lock` and `update` download through
  Yarn, so they use the same setting.

## Supported language repositories

- Registry packages, tarball URLs and GitHub dependencies arrive through
  Yarn's network hook, and the lockfile records them as downloads.
  `registry.yarnpkg.com` and `registry.npmjs.org` serve as each other's
  mirror.
- A git dependency on another host is a `git clone`. The lockfile records
  the URL, the commit, the hash of a checkout, the raw commit object and
  the commits of its submodules. A build rebuilds a repository with that
  commit from the checkout and those, and git's `insteadOf` setting points
  the clone at it. Yarn clones without submodules.
- Yarn packs a git or GitHub dependency by installing it in its
  repository. When the repository is a Yarn project without a `yarn.lock`,
  the lock run records the `yarn.lock` that the nested install resolved, and
  a build writes it back before that install. When the repository uses
  npm or Yarn Classic, its own lockfile names the tarballs that package
  manager downloads, and the lockfile records them where npm and Yarn
  Classic read them offline. A repository that names npm or Yarn 1 in
  `packageManager` and has no lockfile gets one resolved by the lock run.
- The lock run installs the project once for each system. A download that
  only one platform installs, such as one of esbuild's per-platform
  binaries, lists only the systems that fetch it in the `systems` field of
  its entry, and a build fetches the entries for its system and those
  without `systems`.
- `patch:`, `portal:`, `link:` and `file:` dependencies and workspaces come
  from the project source. They have to lie inside `src`, because the
  sandbox sees nothing else.

These are refused or unsupported:

- A package whose install script downloads files itself, outside Yarn,
  fails in the sandbox, because the plugin sees only the downloads that go
  through Yarn. An image library that fetches a prebuilt native library
  while it installs is one example. Such a package can use a library from
  Nix through `buildInputs` when the package supports that, or
  `workspaces` can leave out the workspace that depends on it.
- Yarn itself refuses to pack a git dependency whose repository uses pnpm.
- The lock run covers x86_64-linux, aarch64-linux, x86_64-darwin and
  aarch64-darwin. A build on another system is unsupported, and a build on
  one of these four that the lockfile leaves out fails until the lock run
  covers it.
- The plugin loads through the wrapper. A `yarn plugin import` of
  `plugin/purifier.cjs` alone does not work, because the plugin requires
  `plugin/foreign.cjs` beside it.

The build installs once without running build scripts, patches the
interpreters of scripts and the dynamic loader of prebuilt Linux binaries
in `node_modules` and `.yarn/unplugged`, and installs again to run the
build scripts. node-gyp builds native addons against the headers of the
Node.js that runs the build.

## Examples

For day-to-day work on these projects, use the native-tool setup and
commands in [Quickstart](#quickstart) and [Development loop](#development-loop).
The Nix expressions below show optional sandboxed packaging of those
projects.

### A project in your own repository

In a clone of the repository that one develops, such as a fork of a
Yarn Berry project, run the lock command, commit both lockfiles, and
build with the flake of the Quickstart:

```zsh
nix shell 'github:nix-purifiers/yarn-berry-purifier#toolchain'
yarn-berry-purifier lock
git add yarn.lock yarn-berry-purifier.lock.json
nix build
```

### Prettier, packaged without changing it

Prettier is a project that a user can package without changing it, so its
purifier lockfile lies beside the flake that builds it, outside the
project. This example uses release 3.6.2. Clone that release, and write
the purifier lockfile in a `packaging` directory next to the clone:

```zsh
mkdir packaging
git clone --branch 3.6.2 https://github.com/prettier/prettier
cd prettier
yarn-berry-purifier lock --lockfile \
  ../packaging/prettier.lock.json
yarn-berry-purifier prefetch --lockfile \
  ../packaging/prettier.lock.json
```

The `lock` command installs the clone once for each Nix system and records
the downloads in `packaging/prettier.lock.json`. The `prefetch` command
realizes them in the Nix store, with garbage-collector roots in
`packaging/.yarn-berry-purifier`. In a shell with the `yarn` wrapper, a
developer who sets the variable that names the lockfile can then install
and build the clone with the network cut off:

```zsh
export \
  YARN_BERRY_PURIFIER_LOCKFILE="$PWD/../packaging/prettier.lock.json"
yarn install
yarn build
```

The flake in `packaging/flake.nix` takes prettier as an input that is not
a flake, at the same release, and passes the lockfile beside it to the
builder:

```nix
{
  inputs.yarn-berry-purifier.url =
    "github:nix-purifiers/yarn-berry-purifier";
  inputs.nixpkgs.follows =
    "yarn-berry-purifier/nixpkgs";
  inputs.prettier = {
    url = "github:prettier/prettier/3.6.2";
    flake = false;
  };

  outputs =
    {
      nixpkgs,
      yarn-berry-purifier,
      prettier,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          yarn-berry-purifier.overlays.default
        ];
      };
      project =
        pkgs.yarn-berry-purifier.buildYarnBerryProject
          {
            src = prettier;
            lockFile = ./prettier.lock.json;
          };
    in
    {
      packages.${system}.default =
        project.packages.prettier;
    };
}
```

Nix flakes see only the files that git tracks, so add `flake.nix` and
`prettier.lock.json` to the repository of the packaging flake. Then build
the `prettier` command:

```zsh
cd ../packaging
nix build
```

The purifier lockfile belongs to one `yarn.lock`. After the flake's
`prettier` input moves to another release, run `yarn-berry-purifier lock
--lockfile ../packaging/prettier.lock.json` in a clone of that release.

## Credits

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).

Released under the MIT license; see [LICENSE](LICENSE).
