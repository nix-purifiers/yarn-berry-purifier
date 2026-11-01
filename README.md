# yarn-berry-purifier

A Yarn plugin and a Nix builder for projects that use Yarn Berry (Yarn 3
and later). The plugin records every file Yarn downloads in
`yarn-berry-purifier.lock.json`, and Nix builds the project in its sandbox
from that lockfile. The project needs no Nix files of its own. For Yarn 1,
use [yarn-classic-purifier](https://github.com/nix-purifiers/yarn-classic-purifier).

## Quickstart

In the project, write the purifier lockfile:

```zsh
nix run 'github:nix-purifiers/yarn-berry-purifier#yarn-berry-purifier' -- lock
```

Commit `yarn-berry-purifier.lock.json` with `yarn.lock`. Then build the
project from a flake. The flake's library holds the builder, which takes
the package set to build with:

```nix
{
  inputs.yarn-berry-purifier.url = "github:nix-purifiers/yarn-berry-purifier";
  inputs.nixpkgs.follows = "yarn-berry-purifier/nixpkgs";

  outputs = { nixpkgs, yarn-berry-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      project = yarn-berry-purifier.lib.yarn-berry-purifier.buildYarnBerryProject {
        inherit pkgs;
        src = ./.;
      };
    in
    {
      packages.${system}.my-app = project.packages.my-app;
      checks.${system}.tests = project.tests;
    };
}
```

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
`pkgs` and `src`, they include `fetchers` (replaces fetchers of the
purifier library, such as `fetchurl` for a company mirror or credentials),
`lockFile`, `yarnLock`, `workspaces` (builds only the listed workspaces),
`buildScripts`, `node`, `nativeBuildInputs` and `buildInputs`.

A flake that packages a project it does not change keeps the purifier
lockfile beside itself and passes it as `lockFile`; a `yarnLock` given the
same way replaces the project's `yarn.lock`. Every command takes
`--lockfile <path>` to write or read the purifier lockfile there instead
of at the project root:

```zsh
yarn-berry-purifier lock --lockfile ../packaging/my-app.lock.json
```

## Everyday loop

The everyday loop is Yarn's own commands, run through the flake's `yarn`
wrapper, which loads the plugin from a temporary home directory's
`.yarnrc.yml`. `nix develop github:nix-purifiers/yarn-berry-purifier`
gives a shell with that `yarn`, the `yarn-berry-purifier` command and
Node.js.

In a project with a purifier lockfile, `yarn install` installs from the
locked downloads, which Nix builds under `.yarn/purifier`, and the
project's scripts run as usual with `yarn run`. Add `.yarn/purifier` to
`.gitignore`.

A change to the dependencies goes through Yarn with the plugin's serving
turned off, then a new lock:

```zsh
BERRY_PURIFIER=0 yarn add left-pad
yarn-berry-purifier lock
```

The lock run copies the project into `.yarn/purifier/lock-run` and
installs it there once for each Nix system it covers, which are
x86_64-linux, aarch64-linux, x86_64-darwin and aarch64-darwin by default,
with `supportedArchitectures` set to that system. Each download records the
systems that fetch it, so a build fetches only the per-platform packages of
its own system. The lockfile also records the Yarn release: the one that
`.yarnrc.yml` names in `yarnPath`, or otherwise the release the command
runs in, from repo.yarnpkg.com. `--system` restricts the lock run to the
systems it names. A relock of an unchanged project writes the same
lockfile byte for byte.

`yarn-berry-purifier publish`, run in a workspace, publishes the tarball
that the sandboxed build packs for it, through the same request and with
the same registry, credentials and options as `yarn npm publish`.
`--tarball <file>` publishes a tarball that is already built.

## Offline work

`yarn-berry-purifier prefetch` realizes in the Nix store what the everyday
loop needs for the current system, with garbage-collector roots under
`.yarn/purifier`: the locked downloads, the Yarn release the lockfile
names, and the Node.js and Yarn that the command runs on. Afterwards
`yarn install` and the project's scripts work with the network cut off.

```zsh
yarn-berry-purifier prefetch
```

With `--lockfile`, prefetch also records where the purifier lockfile lies,
so the everyday loop in the project finds it.

## Editor

JavaScript editors take their tools from the project's installed
dependencies: TypeScript's language server comes from the `typescript`
package, and ESLint and Prettier come from their own packages. After
`yarn-berry-purifier prefetch` and `yarn install`, those tools are in place
and work offline. A project that uses Plug'n'Play needs Yarn's editor SDK,
which `yarn dlx @yarnpkg/sdks` installs; `@yarnpkg/sdks` then has to be a
dev dependency, so that the purifier lockfile records it.

## Errors and fixes

Every error names the command that fixes it.

- A build or `yarn install` after a change to `yarn.lock` reports that the
  purifier lockfile "was written for another yarn.lock". Run
  `yarn-berry-purifier lock`.
- A Yarn command that requests a file the lockfile lacks, such as
  `yarn add`, reports that the file "is not in the purifier lockfile". Run
  the Yarn command with `BERRY_PURIFIER=0`, then `yarn-berry-purifier lock`.
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
- A file whose content differs from the locked hash fails its fixed-output
  fetch in Nix, and Yarn's own checksum check fails an install from a
  changed file.

## Sources supported and refused

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
- `patch:`, `portal:`, `link:` and `file:` dependencies and workspaces come
  from the project source. They have to lie inside `src`, because the
  sandbox sees nothing else.

These are refused or unsupported:

- A package whose install script downloads files itself, outside Yarn, such
  as sharp 0.30, which downloads libvips from GitHub, fails in the sandbox,
  because the plugin sees only the downloads that go through Yarn. Such a
  package can use a library from Nix through `buildInputs` when the package
  supports that, or `workspaces` can leave out the workspace that depends on
  it.
- Yarn itself refuses to pack a git dependency whose repository uses pnpm.
- The plugin loads through the wrapper. A `yarn plugin import` of
  `plugin/purifier.cjs` alone does not work, because the plugin requires
  `plugin/foreign.cjs` beside it.

The build installs once without running build scripts, patches the
interpreters of scripts and the dynamic loader of prebuilt Linux binaries
in `node_modules` and `.yarn/unplugged`, and installs again to run the
build scripts. node-gyp builds native addons against the headers of the
Node.js that runs the build.

## Real-world projects

- prettier at `bed4edbb1cf2a9db4004215b0ce5707cdb02b5d9` (Yarn 4.18.1 from
  its `yarnPath`, 927 downloads) builds in the sandbox with its own build
  script, and its installed command formats a file. A flake check builds
  it from the purifier lockfile in `tests/real-world`, kept outside the
  project.
- react-dnd at `1de654eb466b9563fa50df070c244d6f3ab43ca7` (Yarn 3.3.1, 2,428
  downloads) locks. Its documentation site depends on sharp, which
  downloads libvips in its install script, and on lmdb, whose node-gyp
  needed distutils. The `workspaces` argument and the setuptools in the
  default Python came out of this. With `workspaces` set to its library
  packages, the install fails inside Yarn 3.3.1 with "Cannot read
  properties of undefined (reading '/build/yarn-source/.pnp.cjs')" on
  Node.js 22 and 24; the same failure has not been reproduced on a current
  Yarn release.

## Credits

yarn-berry-purifier follows the design of
[sbt-nix-backend](https://github.com/nix-purifiers/sbt-purifier): the build
tool keeps planning the build, a lock run records every download, and Nix
fetches the downloads and runs the build offline in its sandbox. The
shared library of the nix-purifiers,
[purifier](https://github.com/nix-purifiers/purifier), fetches the locked
downloads and git checkouts, and its contract sets the interface that
every purifier shares.

yarn-berry-purifier is licensed under the MIT license.
