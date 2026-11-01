// SPDX-License-Identifier: MIT
//
// The yarn-berry-purifier plugin for Yarn 3 and later.
//
// Yarn sends every download through the `wrapNetworkRequest` hook: the
// registry tarballs, GitHub tarballs, and the downloads of the nested
// installs that pack git dependencies. The plugin wraps that hook in one of
// three modes, chosen by the environment:
//
//   BERRY_PURIFIER_RECORD=<file>  makes each request and appends its
//                                      URL and SHA-512 to <file>, one JSON
//                                      object per line (the lock run)
//   BERRY_PURIFIER_SERVE=<dir>    answers each request from <dir>,
//                                      where Nix laid out the locked files,
//                                      and makes no request (a sandboxed
//                                      build)
//   neither                            in a project whose purifier lockfile
//                                      matches its yarn.lock, builds that
//                                      directory through Nix and serves
//                                      from it (interactive use)
//
// A file lies in the directory at urlPath(url). The plugin also adds the
// `yarn purifier lock` command, which writes yarn-berry-purifier.lock.json.

const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const childProcess = require("child_process");

// The plugin's Nix library and Nix itself. The package that builds the
// plugin replaces these two placeholders with store paths.
const NIX_LIB = "@nixLib@";
const NIXPKGS = "@nixpkgs@";

const PLUGIN_NAME = "@nix-purifiers/plugin-yarn-berry-purifier";
const LOCK_FILE = "yarn-berry-purifier.lock.json";
const LOCK_FORMAT = 1;

// The Nix systems a lockfile covers, as the platform Yarn installs for on
// each.
const SYSTEMS = {
  "x86_64-linux": { os: "linux", cpu: "x64", libc: "glibc" },
  "aarch64-linux": { os: "linux", cpu: "arm64", libc: "glibc" },
  "x86_64-darwin": { os: "darwin", cpu: "x64", libc: "glibc" },
  "aarch64-darwin": { os: "darwin", cpu: "arm64", libc: "glibc" },
};

// The path of a URL's file in the directory of locked files: the scheme,
// the host and the path, and the query encoded into the last segment.
function urlPath(url) {
  const u = new URL(url);
  let p = `${u.protocol.replace(/:$/, "")}/${u.host}${u.pathname}`;
  if (p.endsWith("/")) p += "index";
  if (u.search) p += encodeURIComponent(u.search);
  return p;
}

function sha512(buffer) {
  return `sha512-${crypto.createHash("sha512").update(buffer).digest("base64")}`;
}

// The project root: the nearest directory upwards with a yarn.lock.
function findRoot(cwd) {
  let dir = path.resolve(cwd);
  for (;;) {
    if (fs.existsSync(path.join(dir, "yarn.lock"))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

function inputsHash(root) {
  return `sha256-${crypto.createHash("sha256").update(fs.readFileSync(path.join(root, "yarn.lock"))).digest("base64")}`;
}

// The directory of locked files that interactive use serves from, built
// through Nix once per lockfile and kept under .yarn/purifier, or null when
// the project has no purifier lockfile that matches its yarn.lock.
let interactiveDir;
function interactiveDownloads() {
  if (interactiveDir !== undefined) return interactiveDir;
  interactiveDir = null;
  if (process.env.BERRY_PURIFIER === "0") return null;
  const root = findRoot(process.cwd());
  if (root === null) return null;
  const lockPath = path.join(root, LOCK_FILE);
  if (!fs.existsSync(lockPath)) return null;
  const lock = JSON.parse(fs.readFileSync(lockPath, "utf8"));
  if (lock.inputsHash !== inputsHash(root)) {
    process.stderr.write(
      `yarn-berry-purifier: yarn.lock changed since ${LOCK_FILE} was written; Yarn downloads as usual until \`yarn purifier lock\` renews it.\n`,
    );
    return null;
  }
  const link = path.join(root, ".yarn", "purifier", "downloads");
  const stamp = `${link}.stamp`;
  const current = crypto.createHash("sha256").update(fs.readFileSync(lockPath)).digest("hex");
  if (!fs.existsSync(link) || !fs.existsSync(stamp) || fs.readFileSync(stamp, "utf8") !== current) {
    process.stderr.write(`yarn-berry-purifier: building the downloads of ${lockPath}\n`);
    fs.mkdirSync(path.dirname(link), { recursive: true });
    childProcess.execFileSync(
      "nix",
      [
        "build",
        "--impure",
        "--out-link",
        link,
        "--expr",
        `import ${NIX_LIB}/interactive.nix { pkgs = import ${NIXPKGS} { }; lockFile = /. + builtins.getEnv "BERRY_PURIFIER_LOCK"; }`,
      ],
      { stdio: ["ignore", "inherit", "inherit"], env: { ...process.env, BERRY_PURIFIER_LOCK: lockPath } },
    );
    fs.writeFileSync(stamp, current);
  }
  interactiveDir = link;
  return interactiveDir;
}

function serveFrom(dir, target) {
  const file = path.join(dir, urlPath(target));
  if (!fs.existsSync(file)) {
    throw new Error(
      `yarn-berry-purifier: ${target} is not in ${LOCK_FILE}. Run \`yarn purifier lock\` to record the project's downloads.`,
    );
  }
  return { statusCode: 200, headers: {}, body: fs.readFileSync(file) };
}

function wrapNetworkRequest(executor, extra) {
  const target = String(extra.target);
  const method = (extra.method || "GET").toUpperCase();
  return async () => {
    // Publishing and other writes go to the network as they would without
    // the plugin.
    if (method !== "GET") return executor();
    const record = process.env.BERRY_PURIFIER_RECORD;
    if (record) {
      const response = await executor();
      // A registry's metadata of a package changes with every release, so
      // no hash pins it. A resolution reads metadata, and the lock run
      // records the resolution's result, a yarn.lock, instead.
      if (response.statusCode === 200 && !extra.jsonResponse) {
        fs.appendFileSync(record, `${JSON.stringify({ url: target, hash: sha512(response.body) })}\n`);
      }
      return response;
    }
    const serve = process.env.BERRY_PURIFIER_SERVE;
    if (serve) return serveFrom(serve, target);
    const dir = interactiveDownloads();
    if (dir !== null) return serveFrom(dir, target);
    return executor();
  };
}

// Lifecycle scripts run with the user's own home directory. The commands
// that run Yarn with this plugin give Yarn a temporary home directory whose
// .yarnrc.yml loads the plugin, and keep the real one in
// BERRY_PURIFIER_HOME.
async function setupScriptEnvironment(project, env) {
  if (process.env.BERRY_PURIFIER_HOME) env.HOME = process.env.BERRY_PURIFIER_HOME;
}

// Yarn packs a dependency from a git repository or a GitHub tarball by
// running Yarn in the unpacked repository. When the repository has no
// yarn.lock, Yarn writes an empty one there, and the nested Yarn resolves
// the repository's dependencies against the registry. In the lock run, the
// nested Yarn records the yarn.lock it resolved, keyed by the hash of the
// repository's package.json; in a sandboxed build, the plugin writes that
// yarn.lock into the repository before the nested Yarn reads it.
function externalKey(dir) {
  const manifest = path.join(dir, "package.json");
  if (!fs.existsSync(manifest)) return null;
  return crypto.createHash("sha256").update(fs.readFileSync(manifest)).digest("hex");
}

function restoreExternalLockfile() {
  const serve = process.env.BERRY_PURIFIER_SERVE;
  if (!serve) return;
  const cwd = process.cwd();
  const lockfile = path.join(cwd, "yarn.lock");
  if (fs.existsSync(lockfile) && fs.readFileSync(lockfile, "utf8").trim() !== "") return;
  const key = externalKey(cwd);
  if (key === null) return;
  const recorded = path.join(serve, "external", `${key}.lock`);
  if (fs.existsSync(recorded)) fs.writeFileSync(lockfile, fs.readFileSync(recorded));
}

async function afterAllInstalled(project) {
  const record = process.env.BERRY_PURIFIER_RECORD;
  if (!record || path.resolve(project.cwd) === process.env.BERRY_PURIFIER_MAIN) return;
  const key = externalKey(project.cwd);
  if (key === null) return;
  fs.appendFileSync(record, `${JSON.stringify({ external: key, yarnLock: project.generateLockfile() })}\n`);
}

// The text of a .yarnrc.yml that loads this plugin, with the settings of
// the user's own ~/.yarnrc.yml when there is one.
function homeRc(realHome) {
  const entry = `  - path: ${JSON.stringify(__filename)}\n    spec: ${JSON.stringify(PLUGIN_NAME)}\n`;
  const own = path.join(realHome, ".yarnrc.yml");
  const text = fs.existsSync(own) ? fs.readFileSync(own, "utf8") : "";
  if (/^plugins:\s*$/m.test(text)) return text.replace(/^plugins:\s*$/m, (line) => `${line}\n${entry.trimEnd()}`);
  return `${text}${text === "" || text.endsWith("\n") ? "" : "\n"}plugins:\n${entry}`;
}

module.exports = {
  name: PLUGIN_NAME,
  factory: (require) => {
    restoreExternalLockfile();
    const { BaseCommand } = require("@yarnpkg/cli");
    const { Configuration, Project, httpUtils, YarnVersion } = require("@yarnpkg/core");
    const { Option } = require("clipanion");

    class LockCommand extends BaseCommand {
      static paths = [["purifier", "lock"]];

      systems = Option.Array("--system", {
        description: "A Nix system to lock for; the default is every system yarn-berry-purifier knows",
      });

      async execute() {
        const configuration = await Configuration.find(this.context.cwd, this.context.plugins);
        const { project } = await Project.find(configuration, this.context.cwd);
        const root = project.cwd.startsWith("/") ? project.cwd : path.resolve(project.cwd);
        const systems = this.systems && this.systems.length > 0 ? this.systems : Object.keys(SYSTEMS);
        for (const system of systems) {
          if (!SYSTEMS[system]) throw new Error(`yarn-berry-purifier: unknown system ${system}`);
        }

        // The lock runs work in copies of the project inside it, so they
        // read the .yarnrc.yml files of the directories above the project,
        // which may hold registry or proxy settings.
        const work = path.join(root, ".yarn", "purifier", "lock-run");
        fs.rmSync(work, { recursive: true, force: true });
        fs.mkdirSync(work, { recursive: true });
        try {
          const downloads = new Map();
          const externals = new Map();
          const realHome = process.env.BERRY_PURIFIER_HOME || os.homedir();
          const home = path.join(work, "home");
          fs.mkdirSync(home);
          fs.writeFileSync(path.join(home, ".yarnrc.yml"), homeRc(realHome));

          for (const system of systems) {
            this.context.stdout.write(`yarn-berry-purifier: locking for ${system}\n`);
            const copy = path.join(work, system);
            copyProject(root, copy);
            const platform = SYSTEMS[system];
            // The copy installs for one platform.
            await Configuration.updateConfiguration(copy, {
              supportedArchitectures: { os: [platform.os], cpu: [platform.cpu], libc: [platform.libc] },
            });
            const records = path.join(work, `${system}.records`);
            fs.writeFileSync(records, "");
            const result = childProcess.spawnSync(
              process.execPath,
              [process.argv[1], "install", "--immutable", "--mode=skip-build"],
              {
                cwd: copy,
                stdio: ["ignore", "inherit", "inherit"],
                env: {
                  ...process.env,
                  HOME: home,
                  BERRY_PURIFIER_HOME: realHome,
                  BERRY_PURIFIER_RECORD: records,
                  BERRY_PURIFIER_MAIN: path.resolve(copy),
                  BERRY_PURIFIER_SERVE: "",
                  YARN_ENABLE_GLOBAL_CACHE: "false",
                  YARN_CACHE_FOLDER: path.join(work, `${system}.cache`),
                  YARN_GLOBAL_FOLDER: path.join(work, `${system}.global`),
                  YARN_ENABLE_MIRROR: "false",
                  YARN_ENABLE_IMMUTABLE_CACHE: "false",
                },
              },
            );
            if (result.status !== 0) {
              throw new Error(`yarn-berry-purifier: the lock run for ${system} failed`);
            }
            for (const line of fs.readFileSync(records, "utf8").split("\n")) {
              if (line === "") continue;
              const recorded = JSON.parse(line);
              if (recorded.external) {
                externals.set(recorded.external, recorded.yarnLock);
                continue;
              }
              const { url, hash } = recorded;
              const known = downloads.get(url);
              if (known && known.hash !== hash) {
                throw new Error(`yarn-berry-purifier: ${url} served different files during the lock runs`);
              }
              const entry = known || { path: urlPath(url), url, mirrors: [], hash, systems: [] };
              if (!entry.systems.includes(system)) entry.systems.push(system);
              downloads.set(url, entry);
            }
          }

          const yarn = await lockedYarn(configuration, root);
          const lock = {
            format: LOCK_FORMAT,
            inputsHash: inputsHash(root),
            yarn,
            downloads: [...downloads.values()]
              .map((d) => ({ ...d, mirrors: registryMirrors(d.url), systems: d.systems.sort() }))
              .sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0)),
            externals: [...externals.entries()]
              .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
              .map(([key, yarnLock]) => ({ key, yarnLock })),
          };
          fs.writeFileSync(path.join(root, LOCK_FILE), `${JSON.stringify(lock, null, 2)}\n`);
          this.context.stdout.write(`yarn-berry-purifier: wrote ${path.join(root, LOCK_FILE)}\n`);
          return 0;
        } finally {
          fs.rmSync(work, { recursive: true, force: true });
        }
      }
    }

    // `yarn purifier publish` publishes the tarball that a sandboxed build
    // packs for the current workspace, as `yarn npm publish` would publish
    // the tarball it packs itself, with the same registry, credentials and
    // options. `--tarball` publishes a tarball that is already built.
    class PublishCommand extends BaseCommand {
      static paths = [["purifier", "publish"]];

      access = Option.String("--access", { description: "The access for the published package (public or restricted)" });
      tag = Option.String("--tag", "latest", { description: "The tag on the registry that the package should be attached to" });
      otp = Option.String("--otp", { description: "The OTP token to use with the command" });
      tarball = Option.String("--tarball", { description: "Publish this tarball instead of building one" });

      async execute() {
        const { npmConfigUtils, npmHttpUtils, npmPublishUtils } = require("@yarnpkg/plugin-npm");
        const { structUtils } = require("@yarnpkg/core");
        const configuration = await Configuration.find(this.context.cwd, this.context.plugins);
        const { project, workspace } = await Project.find(configuration, this.context.cwd);
        if (!workspace || !workspace.manifest.name) {
          throw new Error("yarn-berry-purifier: run `yarn purifier publish` in the workspace to publish");
        }
        const ident = workspace.manifest.name;
        const name = structUtils.stringifyIdent(ident);
        let tarball = this.tarball;
        if (!tarball) {
          this.context.stdout.write(`yarn-berry-purifier: building the tarball of ${name}\n`);
          const out = childProcess
            .execFileSync(
              "nix",
              [
                "build",
                "--impure",
                "--no-link",
                "--print-out-paths",
                "--expr",
                `import ${NIX_LIB}/publish.nix { pkgs = import ${NIXPKGS} { }; src = /. + builtins.getEnv "BERRY_PURIFIER_SRC"; package = builtins.getEnv "BERRY_PURIFIER_PACKAGE"; }`,
              ],
              {
                stdio: ["ignore", "pipe", "inherit"],
                env: { ...process.env, BERRY_PURIFIER_SRC: path.resolve(project.cwd), BERRY_PURIFIER_PACKAGE: name },
              },
            )
            .toString()
            .trim();
          tarball = path.join(out, "package.tgz");
        }
        const buffer = fs.readFileSync(tarball);
        const registry = npmConfigUtils.getPublishRegistry(workspace.manifest, { configuration });
        const body = await npmPublishUtils.makePublishBody(workspace, buffer, {
          access: this.access,
          tag: this.tag,
          registry,
        });
        await npmHttpUtils.put(npmHttpUtils.getIdentUrl(ident), body, {
          configuration,
          registry,
          ident,
          otp: this.otp,
          jsonResponse: true,
        });
        this.context.stdout.write(`yarn-berry-purifier: published ${tarball} as ${name}\n`);
        return 0;
      }
    }

    // The Yarn a sandboxed build runs: the release that .yarnrc.yml names
    // in yarnPath, which lies in the project, or else the release this
    // command runs in, downloaded from repo.yarnpkg.com.
    async function lockedYarn(configuration, root) {
      const yarnPath = configuration.get("yarnPath");
      if (yarnPath) {
        return { path: path.relative(root, String(yarnPath)) };
      }
      const url = `https://repo.yarnpkg.com/${YarnVersion}/packages/yarnpkg-cli/bin/yarn.js`;
      const body = await httpUtils.get(url, { configuration });
      return { version: YarnVersion, url, hash: sha512(body) };
    }

    return {
      hooks: { wrapNetworkRequest, setupScriptEnvironment, afterAllInstalled },
      commands: [LockCommand, PublishCommand],
    };
  },
};

// Yarn's registry and npm's registry serve the same tarballs at the same
// paths, so a tarball from either has the other as its mirror.
function registryMirrors(url) {
  const yarn = "https://registry.yarnpkg.com/";
  const npm = "https://registry.npmjs.org/";
  if (url.startsWith(yarn)) return [npm + url.slice(yarn.length)];
  if (url.startsWith(npm)) return [yarn + url.slice(npm.length)];
  return [];
}

// Copies the project for a lock run, without what an install writes and
// without .yarn/purifier, where the copies lie.
function copyProject(from, to) {
  const skip = new Set(["node_modules", ".git", ".pnp.cjs", ".pnp.loader.mjs", ".pnp.data.json"]);
  const skipYarn = new Set(["cache", "unplugged", "install-state.gz", "build-state.yml", "purifier"]);
  const filter = (source) => !path.relative(from, source).split(path.sep).some((p) => skip.has(p));
  fs.mkdirSync(to, { recursive: true });
  for (const name of fs.readdirSync(from)) {
    if (skip.has(name)) continue;
    if (name === ".yarn") {
      fs.mkdirSync(path.join(to, name));
      for (const inner of fs.readdirSync(path.join(from, name))) {
        if (skipYarn.has(inner)) continue;
        fs.cpSync(path.join(from, name, inner), path.join(to, name, inner), { recursive: true, filter });
      }
      continue;
    }
    fs.cpSync(path.join(from, name), path.join(to, name), { recursive: true, filter });
  }
}
