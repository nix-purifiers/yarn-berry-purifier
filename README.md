# yarn-berry-purifier

A Yarn plugin and a Nix builder for projects that use Yarn Berry (Yarn 3
and later). The plugin records every file Yarn downloads in
`yarn-berry-purifier.lock.json`, and Nix builds the project in its sandbox
from that lockfile. The project needs no Nix files of its own.

For Yarn 1, use
[yarn-classic-purifier](https://github.com/nix-purifiers/yarn-classic-purifier).

yarn-berry-purifier follows the design of
[sbt-nix-backend](https://github.com/nix-purifiers/sbt-purifier): the build
tool keeps planning the build, a lock run records every download, and Nix
fetches the downloads and runs the build offline in its sandbox.

## How it works

Yarn sends every download through its `wrapNetworkRequest` plugin hook. The
plugin wraps that hook in one of three modes:

- In the lock run, it makes each request and records the URL and the
  SHA-512 of the file.
- In a sandboxed build, it answers each request from a directory that Nix
  laid out from the lockfile, and makes no request.
- In interactive use, in a project whose purifier lockfile matches its
  `yarn.lock`, it builds that directory through Nix, under
  `.yarn/purifier`, and serves from it.

`yarn purifier lock` runs the lock run. It copies the project into
`.yarn/purifier/lock-run` and installs it there once for each Nix system it
covers (x86_64-linux, aarch64-linux, x86_64-darwin and aarch64-darwin by
default), with `supportedArchitectures` set to that system. Each download
records the systems that fetch it, so a build fetches only the
per-platform packages of its own system, such as one of esbuild's
binaries. The lockfile also records the Yarn release: the one that
`.yarnrc.yml` names in `yarnPath`, or otherwise the release the command runs
in, from repo.yarnpkg.com.

A build checks that the purifier lockfile was written for the project's
current `yarn.lock`, and fails with the command to run when it was not.

### Dependency sources

- Registry packages, tarball URLs and GitHub dependencies arrive through
  Yarn's network hook, and the lockfile records them as downloads.
  `registry.yarnpkg.com` and `registry.npmjs.org` serve as each other's
  mirror.
- A git dependency on another host is a `git clone`. The lockfile records
  the URL, the commit, the hash of a checkout and the raw commit object. A
  build rebuilds a repository with that commit from the checkout and the
  object, and git's `insteadOf` setting points the clone at it. Yarn clones
  without submodules.
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

The project's own packages come from its `package.json` files: the root, and
the workspaces that the root's `workspaces` globs name.

## Use

Run Yarn with the plugin loaded through the flake's wrapper, which loads
the plugin from a temporary home directory's `.yarnrc.yml`, so the project
needs no change:

```zsh
nix run github:nix-purifiers/yarn-berry-purifier -- purifier lock
```

Commit `yarn-berry-purifier.lock.json` with `yarn.lock`, and run the command
again after every change to `yarn.lock`.
`nix develop github:nix-purifiers/yarn-berry-purifier` gives a shell where
`yarn` is the wrapper. With the plugin loaded, `yarn install` in a project
with a current purifier lockfile installs offline from the locked files;
`BERRY_PURIFIER=0` turns that off.

The flake's `overlays.default` adds `buildYarnBerryProject` to a package
set, and a package written for `callPackage` takes it by name:

```nix
# package.nix
{ buildYarnBerryProject }:
(buildYarnBerryProject { src = ./.; }).packages.my-app
```

```nix
{
  inputs.yarn-berry-purifier.url = "github:nix-purifiers/yarn-berry-purifier";
  inputs.nixpkgs.follows = "yarn-berry-purifier/nixpkgs";

  outputs = { nixpkgs, yarn-berry-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          yarn-berry-purifier.overlays.default
          (final: prev: { my-app = final.callPackage ./package.nix { }; })
        ];
      };
    in
    {
      packages.${system}.my-app = pkgs.my-app;
    };
}
```

`buildYarnBerryProject` returns these attributes:

- `packages.<name>` is package `<name>` of the project, installed with its
  production dependencies under `lib/node_modules`, with its commands in
  `bin/`. Its `tarball` output holds `package.tgz`, the file
  `yarn npm publish` uploads.
- `build` is the project after `yarn install`, its build scripts and
  `yarn pack`, as one tarball per package.
- `productionModules` holds the production dependencies, installed by
  `yarn workspaces focus --production` with the node-modules linker.
- `dependencies` is the directory the plugin serves from.

`nix/lib/build-yarn-berry-project.nix` documents the arguments, among them
`workspaces` (builds only the listed workspaces), `buildScripts`, `doCheck`,
`node`, `nativeBuildInputs`, `buildInputs` and `lockFile`.

The build installs once without running build scripts, patches the
interpreters of scripts and the dynamic loader of prebuilt Linux binaries
in `node_modules` and `.yarn/unplugged`, and installs again to run the
build scripts. node-gyp builds native addons against the headers of the
Node.js that runs the build.

`yarn purifier publish` publishes the tarball that a sandboxed build packs
for the current workspace, through the same request and with the same
registry, credentials and options as `yarn npm publish`.
`yarn purifier publish --tarball <file>` publishes a tarball that is
already built.

## Limitations

- The plugin loads through the wrapper. A `yarn plugin import` of
  `plugin/purifier.cjs` alone does not work, because the plugin requires
  `plugin/foreign.cjs` beside it.
- A package whose install script downloads files itself, outside Yarn, such
  as sharp 0.30, which downloads libvips from GitHub, fails in the sandbox,
  because the plugin sees only the downloads that go through Yarn. Such a
  package can use a library from Nix through `buildInputs` when the package
  supports that, or `workspaces` can leave out the workspace that depends on
  it.
- Yarn itself refuses to pack a git dependency whose repository uses pnpm.
- The lock run covers four systems by default. `--system` restricts it, and
  a build on a system the lockfile does not cover fails with the command to
  run.

## Projects tried

- react-dnd at `1de654eb466b9563fa50df070c244d6f3ab43ca7` (Yarn 3.3.1, 2,428
  downloads). The lock run works. Its documentation site depends on sharp,
  which downloads libvips in its install script, and on lmdb, whose node-gyp
  needed distutils; the `workspaces` argument and the setuptools in the
  default Python came out of this. The build of its library packages fails
  inside Yarn 3.3.1 while it runs the workspace scripts, which is not yet
  resolved.

## License

MIT
