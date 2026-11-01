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
//   neither                            in a project with a purifier
//                                      lockfile, builds that directory
//                                      through Nix and serves from it
//                                      (interactive use)
//
// A file lies in the directory at urlPath(url). The plugin also adds the
// `yarn purifier lock`, `yarn purifier prefetch` and `yarn purifier
// publish` commands, which the `yarn-berry-purifier` command runs as
// `yarn-berry-purifier lock`, `prefetch` and `publish`.

const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const childProcess = require("child_process");
const foreign = require("./foreign.cjs");

// The plugin's Nix library and Nix itself. The package that builds the
// plugin replaces these two placeholders with store paths.
const NIX_LIB = "@nixLib@";
const NIXPKGS = "@nixpkgs@";
// The source of this flake, whose `lib.purifier` output is the shared
// purifier library that interactive use and publishing build with.
const FLAKE = "@flake@";
const PURIFIER = `(builtins.getFlake "path:${FLAKE}").lib.purifier`;

const PLUGIN_NAME = "@nix-purifiers/plugin-yarn-berry-purifier";
const LOCK_FILE = "yarn-berry-purifier.lock.json";
const LOCK_VERSION = 1;
const LOCK_COMMAND = "yarn-berry-purifier lock";

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

function sha256(buffer) {
  return `sha256-${crypto.createHash("sha256").update(buffer).digest("base64")}`;
}

function inputsHash(root) {
  return sha256(fs.readFileSync(path.join(root, "yarn.lock")));
}

// A value with the keys of every object sorted, so that JSON.stringify
// writes it as Nix's builtins.toJSON writes the same value.
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value !== null && typeof value === "object") {
    const sorted = {};
    for (const key of Object.keys(value).sort()) sorted[key] = canonical(value[key]);
    return sorted;
  }
  return value;
}

// The hash a purifier lockfile records of its own content: the SHA-256 of
// the lockfile without `contentHash`, written as canonical JSON with no
// whitespace. nix/lib/lock.nix computes the same hash.
function contentHash(lock) {
  const { contentHash: _, ...rest } = lock;
  return sha256(JSON.stringify(canonical(rest)));
}

// Reads the purifier lockfile at lockPath for the project at root, and
// throws an error that names the command to run when the lockfile is
// malformed, edited, or written for another yarn.lock.
function readLock(lockPath, root) {
  const fail = (problem) => {
    throw new Error(`yarn-berry-purifier: ${lockPath} ${problem}. Run \`${LOCK_COMMAND}\`.`);
  };
  let lock;
  try {
    lock = JSON.parse(fs.readFileSync(lockPath, "utf8"));
  } catch {
    fail("is not valid JSON");
  }
  if (lock === null || typeof lock !== "object" || Array.isArray(lock)) fail("holds no JSON object");
  if (lock.version !== LOCK_VERSION) {
    fail(`has version ${JSON.stringify(lock.version)}, and this yarn-berry-purifier reads version ${LOCK_VERSION}`);
  }
  if (lock.contentHash !== contentHash(lock)) fail("was changed after it was written; its contentHash does not match");
  if (lock.inputsHash !== inputsHash(root)) fail("was written for another yarn.lock");
  return lock;
}

// The purifier lockfile of the project at root: the one at the root, or
// the one outside the project that the last `yarn-berry-purifier prefetch
// --lockfile` used, or null when there is neither.
function projectLockPath(root) {
  const own = path.join(root, LOCK_FILE);
  if (fs.existsSync(own)) return own;
  const recorded = path.join(root, ".yarn", "purifier", "lockfile");
  if (fs.existsSync(recorded)) {
    const external = fs.readFileSync(recorded, "utf8");
    if (fs.existsSync(external)) return external;
  }
  return null;
}

// Builds the directory of locked files through Nix, unless the one under
// .yarn/purifier was built from the same lockfile, and returns its path.
// The link keeps it alive as a garbage-collector root.
function buildDownloads(root, lockPath) {
  readLock(lockPath, root);
  const link = path.join(root, ".yarn", "purifier", "downloads");
  const stamp = `${link}.stamp`;
  const current = crypto.createHash("sha256").update(fs.readFileSync(lockPath)).digest("hex");
  if (!fs.existsSync(link) || !fs.existsSync(stamp) || fs.readFileSync(stamp, "utf8") !== current) {
    process.stderr.write(`yarn-berry-purifier: building the downloads of ${lockPath}\n`);
    fs.mkdirSync(path.dirname(link), { recursive: true });
    nixBuild(link, "interactive.nix", { BERRY_PURIFIER_LOCK: lockPath, BERRY_PURIFIER_YARN_LOCK: path.join(root, "yarn.lock") });
    fs.writeFileSync(stamp, current);
  }
  return link;
}

// Builds nix/lib/<file> for the purifier lockfile and yarn.lock that the
// environment variables name, with a garbage-collector root at `link`.
function nixBuild(link, file, env) {
  childProcess.execFileSync(
    "nix",
    [
      "build",
      "--impure",
      "--out-link",
      link,
      "--expr",
      `import ${NIX_LIB}/${file} { pkgs = import ${NIXPKGS} { }; purifier = ${PURIFIER}; lockFile = /. + builtins.getEnv "BERRY_PURIFIER_LOCK"; yarnLock = /. + builtins.getEnv "BERRY_PURIFIER_YARN_LOCK"; }`,
    ],
    { stdio: ["ignore", "inherit", "inherit"], env: { ...process.env, ...env } },
  );
}

// The directory of locked files that interactive use serves from, or null
// when the project has no purifier lockfile.
let interactiveDir;
function interactiveDownloads() {
  if (interactiveDir !== undefined) return interactiveDir;
  interactiveDir = null;
  if (process.env.BERRY_PURIFIER === "0") return null;
  const root = findRoot(process.cwd());
  if (root === null) return null;
  const lockPath = projectLockPath(root);
  if (lockPath === null) return null;
  interactiveDir = buildDownloads(root, lockPath);
  return interactiveDir;
}

function serveFrom(dir, target) {
  const file = path.join(dir, urlPath(target));
  if (!fs.existsSync(file)) {
    throw new Error(
      `yarn-berry-purifier: ${target} is not in the purifier lockfile. Run \`${LOCK_COMMAND}\` to record the project's downloads, or set BERRY_PURIFIER=0 to download as Yarn does without the plugin.`,
    );
  }
  return { statusCode: 200, headers: {}, body: fs.readFileSync(file) };
}

// `yarn set version classic` downloads classic.yarnpkg.com/latest.js, whose
// content follows the newest Yarn Classic release. The release of the same
// version on GitHub serves the same file at a URL that stays, and a build
// fetches that URL first.
function stableUrl(url, body) {
  if (url !== "https://classic.yarnpkg.com/latest.js") return null;
  const m = /"name":"yarn","installationMethod":"[^"]*","version":"(1\.\d+\.\d+)"/.exec(body.toString("utf8"));
  return m ? `https://github.com/yarnpkg/yarn/releases/download/v${m[1]}/yarn-${m[1]}.js` : null;
}

// A GitHub dependency arrives as an archive of the repository. When Yarn
// packs that repository with npm or Yarn Classic, the lock run needs the
// repository's package.json and lockfiles, which lie at the top of the
// archive.
function isGithubArchive(url) {
  const u = new URL(url);
  return (u.host === "github.com" && u.pathname.includes("/archive/")) || u.host === "codeload.github.com";
}

function recordForeign(record, body) {
  let files;
  try {
    files = foreign.topLevelFiles(body, ["package.json", "package-lock.json", "yarn.lock"]);
  } catch {
    return;
  }
  if (!files["package.json"]) return;
  fs.appendFileSync(
    record,
    `${JSON.stringify({
      foreign: {
        manifest: files["package.json"].toString("utf8"),
        npmLock: files["package-lock.json"] ? files["package-lock.json"].toString("utf8") : null,
        yarnLock: files["yarn.lock"] ? files["yarn.lock"].toString("utf8") : null,
      },
    })}\n`,
  );
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
        const type = String((response.headers || {})["content-type"] || "");
        if (type.includes("json") && response.body.length < 65536) {
          // A small JSON document, such as the list of Yarn releases that
          // `yarn set version` reads, changes as releases appear, so the
          // lockfile holds its text as `contents`.
          fs.appendFileSync(record, `${JSON.stringify({ url: target, contents: response.body.toString("utf8") })}\n`);
        } else {
          fs.appendFileSync(
            record,
            `${JSON.stringify({ url: target, hash: sha512(response.body), stable: stableUrl(target, response.body) })}\n`,
          );
        }
        if (isGithubArchive(target)) recordForeign(record, response.body);
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

// The text of a .yarnrc for Yarn Classic, which Yarn runs to pack git
// dependencies that use it: the user's own ~/.yarnrc, and a mutex, because
// Yarn packs those dependencies in parallel and Yarn Classic installs into
// a shared cache that only one Yarn Classic may write at a time.
function classicRc(realHome, mutex) {
  const own = path.join(realHome, ".yarnrc");
  const text = fs.existsSync(own) ? fs.readFileSync(own, "utf8") : "";
  return `${text}${text === "" || text.endsWith("\n") ? "" : "\n"}--mutex "file:${mutex}"\n`;
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

      lockfile = Option.String("--lockfile", {
        description: `Write the purifier lockfile at this path instead of ${LOCK_FILE} at the project root`,
      });

      async execute() {
        // The lock command downloads what it records, also in a project
        // whose current purifier lockfile interactive use would serve from.
        process.env.BERRY_PURIFIER = "0";
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
          const foreigns = new Map();
          const realHome = process.env.BERRY_PURIFIER_HOME || os.homedir();
          const home = path.join(work, "home");
          fs.mkdirSync(home);
          fs.writeFileSync(path.join(home, ".yarnrc.yml"), homeRc(realHome));
          fs.writeFileSync(path.join(home, ".yarnrc"), classicRc(realHome, path.join(work, "yarn-classic.mutex")));

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
              if (recorded.foreign) {
                foreigns.set(foreign.manifestHash(recorded.foreign.manifest), recorded.foreign);
                continue;
              }
              const { url, hash, contents, stable } = recorded;
              const known = downloads.get(urlPath(url));
              if (known && (known.hash !== hash || known.contents !== contents)) {
                throw new Error(`yarn-berry-purifier: ${url} served different files during the lock runs`);
              }
              const entry =
                known ||
                (contents !== undefined
                  ? { path: urlPath(url), contents, systems: [] }
                  : stable
                    ? { path: urlPath(url), url: stable, mirrors: [url], hash, systems: [] }
                    : { path: urlPath(url), url, mirrors: [], hash, systems: [] });
              if (!entry.systems.includes(system)) entry.systems.push(system);
              downloads.set(entry.path, entry);
            }
          }

          const repositories = await lockedRepositories(path.join(work, systems[0]), this.context.plugins, foreigns, work);

          // The tarballs that npm or Yarn Classic downloads when Yarn packs
          // a git or GitHub dependency with them.
          const npmLocks = new Map();
          for (const [hash, files] of foreigns) {
            let found = foreign.foreignDownloads(files, systems);
            if (found === null) {
              // A repository that names npm or Yarn Classic in
              // packageManager and has no lockfile gets one here, resolved
              // once. A build writes it into the repository before the
              // package manager runs: npm's through the `npm` command in
              // front of npm on the PATH, and Yarn Classic's through this
              // plugin, which runs in the repository when Yarn switches it to
              // Yarn Classic.
              const resolved = resolveForeignLockfile(files.manifest, work);
              if (resolved.npmLock) npmLocks.set(hash, resolved.npmLock);
              if (resolved.yarnLock) externals.set(hash, resolved.yarnLock);
              found = foreign.foreignDownloads({ ...files, ...resolved }, systems);
            }
            for (const d of found) {
              const known = downloads.get(d.path);
              const entry = known || { path: d.path, url: d.url, mirrors: [], hash: d.hash, systems: [] };
              for (const system of d.systems) if (!entry.systems.includes(system)) entry.systems.push(system);
              downloads.set(entry.path, entry);
            }
          }

          const yarn = await lockedYarn(configuration, root);
          const content = {
            inputsHash: inputsHash(root),
            yarn,
            downloads: [...downloads.values()]
              .map((d) =>
                d.contents !== undefined
                  ? { ...d, systems: d.systems.sort() }
                  : { ...d, mirrors: d.mirrors.length > 0 ? d.mirrors : registryMirrors(d.url), systems: d.systems.sort() },
              )
              .sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0)),
            repositories,
            npmLocks: [...npmLocks.entries()]
              .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
              .map(([manifestHash, packageLock]) => ({ manifestHash, packageLock })),
            externals: [...externals.entries()]
              .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
              .map(([manifestHash, yarnLock]) => ({ manifestHash, yarnLock })),
          };
          const lockPath = this.lockfile ? path.resolve(this.context.cwd, this.lockfile) : path.join(root, LOCK_FILE);
          writeLock(lockPath, content);
          this.context.stdout.write(`yarn-berry-purifier: wrote ${lockPath}\n`);
          return 0;
        } finally {
          fs.rmSync(work, { recursive: true, force: true });
        }
      }
    }

    // `yarn purifier prefetch` realizes in the Nix store what the everyday
    // loop needs from the purifier lockfile for the current system, and
    // keeps it alive with garbage-collector roots under .yarn/purifier: the
    // locked downloads, which the plugin then serves to `yarn install`; the
    // Yarn release the lockfile names; and the Node.js and Yarn this
    // command runs on. Afterwards `yarn install` and the project's scripts
    // run with no network. Editors read the project's tools, such as
    // TypeScript's language server, from the installed dependencies.
    class PrefetchCommand extends BaseCommand {
      static paths = [["purifier", "prefetch"]];

      lockfile = Option.String("--lockfile", {
        description: `Read the purifier lockfile at this path instead of ${LOCK_FILE} at the project root`,
      });

      async execute() {
        const configuration = await Configuration.find(this.context.cwd, this.context.plugins);
        const { project } = await Project.find(configuration, this.context.cwd);
        const root = path.resolve(project.cwd);
        const own = path.join(root, LOCK_FILE);
        const lockPath = this.lockfile ? path.resolve(this.context.cwd, this.lockfile) : own;
        if (!fs.existsSync(lockPath)) {
          throw new Error(`yarn-berry-purifier: ${lockPath} does not exist. Run \`${LOCK_COMMAND}\`.`);
        }
        const lock = readLock(lockPath, root);
        const dir = path.join(root, ".yarn", "purifier");
        fs.mkdirSync(dir, { recursive: true });
        // Interactive use finds a purifier lockfile outside the project
        // through this file.
        const recorded = path.join(dir, "lockfile");
        if (lockPath === own) fs.rmSync(recorded, { force: true });
        else fs.writeFileSync(recorded, lockPath);
        buildDownloads(root, lockPath);
        if (lock.yarn && lock.yarn.url) {
          nixBuild(path.join(dir, "yarn-release"), "release.nix", {
            BERRY_PURIFIER_LOCK: lockPath,
            BERRY_PURIFIER_YARN_LOCK: path.join(root, "yarn.lock"),
          });
        }
        for (const [name, file] of [
          ["node", process.execPath],
          ["yarn", process.argv[1]],
        ]) {
          const store = /^\/nix\/store\/[^/]+/.exec(fs.realpathSync(file));
          if (!store) continue;
          childProcess.execFileSync("nix-store", ["--realise", store[0], "--add-root", path.join(dir, name)], {
            stdio: ["ignore", "ignore", "inherit"],
          });
        }
        this.context.stdout.write(`yarn-berry-purifier: prefetched ${lockPath} into ${dir}\n`);
        return 0;
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
      lockfile = Option.String("--lockfile", {
        description: `Build with the purifier lockfile at this path instead of ${LOCK_FILE} at the project root`,
      });

      async execute() {
        const { npmConfigUtils, npmHttpUtils, npmPublishUtils } = require("@yarnpkg/plugin-npm");
        const { structUtils } = require("@yarnpkg/core");
        const configuration = await Configuration.find(this.context.cwd, this.context.plugins);
        const { project, workspace } = await Project.find(configuration, this.context.cwd);
        if (!workspace || !workspace.manifest.name) {
          throw new Error("yarn-berry-purifier: run `yarn-berry-purifier publish` in the workspace to publish");
        }
        const ident = workspace.manifest.name;
        const name = structUtils.stringifyIdent(ident);
        let tarball = this.tarball;
        if (!tarball) {
          this.context.stdout.write(`yarn-berry-purifier: building the tarball of ${name}\n`);
          const root = path.resolve(project.cwd);
          const lockPath = this.lockfile ? path.resolve(this.context.cwd, this.lockfile) : path.join(root, LOCK_FILE);
          const out = childProcess
            .execFileSync(
              "nix",
              [
                "build",
                "--impure",
                "--no-link",
                "--print-out-paths",
                "--expr",
                `import ${NIX_LIB}/publish.nix { pkgs = import ${NIXPKGS} { }; purifier = ${PURIFIER}; src = /. + builtins.getEnv "BERRY_PURIFIER_SRC"; lockFile = /. + builtins.getEnv "BERRY_PURIFIER_LOCK"; package = builtins.getEnv "BERRY_PURIFIER_PACKAGE"; }`,
              ],
              {
                stdio: ["ignore", "pipe", "inherit"],
                env: {
                  ...process.env,
                  BERRY_PURIFIER_SRC: root,
                  BERRY_PURIFIER_LOCK: lockPath,
                  BERRY_PURIFIER_PACKAGE: name,
                },
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

    // The git repositories that Yarn clones for the project: every git
    // dependency that is not on GitHub, whose tarballs Yarn downloads
    // instead. Each is recorded with the URL Yarn clones, the locked commit,
    // the hash of its checkout as nix-prefetch-git reports it, and its raw
    // commit object. A sandboxed build serves the clones from repositories
    // it rebuilds from those.
    // The commit object of `rev` in the shape of the shared purifier
    // library: `object` is the raw commit object in base64, and `gitlinks`
    // lists the submodule commits of its tree as { path, rev }. A build
    // rebuilds the .git directory of a clone from the checkout and these,
    // because a checkout that keeps its .git directory has no reproducible
    // hash.
    function commitObject(url, rev, work) {
      const dir = fs.mkdtempSync(path.join(work, "commit-"));
      const git = (args) => {
        const result = childProcess.spawnSync("git", args, { cwd: dir, stdio: ["ignore", "pipe", "inherit"] });
        if (result.status !== 0) throw new Error(`yarn-berry-purifier: git ${args.join(" ")} failed for ${url}`);
        return result.stdout;
      };
      git(["init", "-q"]);
      git(["fetch", "-q", "--depth=1", url, rev]);
      const gitlinks = git(["ls-tree", "-r", "-z", rev])
        .toString("utf8")
        .split("\0")
        .filter((line) => line.startsWith("160000 "))
        .map((line) => {
          const [meta, linkPath] = line.split("\t");
          return { path: linkPath, rev: meta.split(" ")[2] };
        });
      return { object: git(["cat-file", "commit", rev]).toString("base64"), gitlinks };
    }

    async function lockedRepositories(copy, plugins, foreigns, work) {
      const { gitUtils } = require("@yarnpkg/plugin-git");
      const { githubUtils } = require("@yarnpkg/plugin-github");
      const copyConfiguration = await Configuration.find(copy, plugins);
      const { project } = await Project.find(copyConfiguration, copy);
      const found = new Map();
      // `originalPackages` holds the packages of the yarn.lock that
      // Project.find reads.
      for (const pkg of project.originalPackages.values()) {
        const reference = pkg.reference;
        if (!gitUtils.isGitUrl(reference) || githubUtils.isGithubUrl(reference)) continue;
        const { repo, treeish } = gitUtils.splitRepoUrl(reference);
        if (treeish.protocol !== "commit") continue;
        const remote = gitUtils.normalizeRepoUrl(repo, { git: true });
        found.set(`${remote}#${treeish.request}`, { remote, rev: treeish.request });
      }
      const repositories = [];
      for (const { remote, rev } of found.values()) {
        const url = fetchUrl(remote);
        const prefetch = process.env.BERRY_PURIFIER_PREFETCH_GIT || "nix-prefetch-git";
        const result = childProcess.spawnSync(prefetch, ["--url", url, "--rev", rev, "--quiet"], {
          stdio: ["ignore", "pipe", "inherit"],
        });
        if (result.status !== 0) throw new Error(`yarn-berry-purifier: ${prefetch} failed for ${url} at ${rev}`);
        const prefetched = JSON.parse(result.stdout.toString());
        const { hash } = prefetched;
        // The checkout's package.json and lockfiles, for a repository that
        // Yarn packs with npm or Yarn Classic.
        if (prefetched.path && fs.existsSync(path.join(prefetched.path, "package.json"))) {
          const read = (name) =>
            fs.existsSync(path.join(prefetched.path, name)) ? fs.readFileSync(path.join(prefetched.path, name), "utf8") : null;
          const files = { manifest: read("package.json"), npmLock: read("package-lock.json"), yarnLock: read("yarn.lock") };
          foreigns.set(foreign.manifestHash(files.manifest), files);
        }
        repositories.push({
          path: `git/${rev}`,
          git: { url, rev, submodules: false, leaveDotGit: true, commitObject: commitObject(url, rev, work) },
          hash,
          remote,
        });
      }
      return repositories.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
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
      commands: [LockCommand, PrefetchCommand, PublishCommand],
    };
  },
};

// Writes a purifier lockfile with the given content, its version and the
// hash of its content, as JSON indented by two spaces.
function writeLock(lockPath, content) {
  const withVersion = { version: LOCK_VERSION, ...content };
  const lock = { version: LOCK_VERSION, contentHash: contentHash(withVersion), ...content };
  fs.writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`);
}

// Yarn's registry and npm's registry serve the same tarballs at the same
// paths, so a tarball from either has the other as its mirror.
function registryMirrors(url) {
  const yarn = "https://registry.yarnpkg.com/";
  const npm = "https://registry.npmjs.org/";
  if (url.startsWith(yarn)) return [npm + url.slice(yarn.length)];
  if (url.startsWith(npm)) return [yarn + url.slice(npm.length)];
  return [];
}

// Resolves the lockfile of a repository that names npm or Yarn Classic in
// packageManager and has none, from its package.json alone, as the package
// manager would resolve it during the install.
function resolveForeignLockfile(manifest, work) {
  const dir = fs.mkdtempSync(path.join(work, "foreign-"));
  fs.writeFileSync(path.join(dir, "package.json"), manifest);
  const name = JSON.parse(manifest).packageManager.split("@")[0];
  const run = (command, args) => {
    const result = childProcess.spawnSync(command, args, {
      cwd: dir,
      stdio: ["ignore", "inherit", "inherit"],
      env: { ...process.env, BERRY_PURIFIER_RECORD: "", BERRY_PURIFIER_SERVE: "" },
    });
    if (result.status !== 0) throw new Error(`yarn-berry-purifier: ${command} ${args.join(" ")} failed in ${dir}`);
  };
  if (name === "npm") {
    run("npm", ["install", "--package-lock-only", "--ignore-scripts", "--legacy-peer-deps"]);
    return { npmLock: fs.readFileSync(path.join(dir, "package-lock.json"), "utf8") };
  }
  // Yarn puts a Yarn Classic release into the directory, as it does for
  // the install, and that release resolves the dependencies. The empty
  // yarn.lock makes the directory a project of its own.
  fs.writeFileSync(path.join(dir, "yarn.lock"), "");
  run(process.execPath, [process.argv[1], "set", "version", "classic", "--only-if-needed", "--yarn-path"]);
  // `yarn set version` rewrites packageManager; Yarn restores package.json
  // after it in the install too.
  fs.writeFileSync(path.join(dir, "package.json"), manifest);
  const releases = path.join(dir, ".yarn", "releases");
  const release = fs.readdirSync(releases).find((name) => name.startsWith("yarn-classic") || name.startsWith("yarn-1."));
  if (!release) throw new Error(`yarn-berry-purifier: \`yarn set version classic\` put no release into ${releases}`);
  run(process.execPath, [path.join(releases, release), "install", "--ignore-scripts", "--non-interactive"]);
  return { yarnLock: fs.readFileSync(path.join(dir, "yarn.lock"), "utf8") };
}

// The URL a checkout of a repository is fetched from: the ssh URL of a
// public forge becomes its https URL, which serves the same repository
// without credentials.
function fetchUrl(remote) {
  const forge = /^ssh:\/\/(?:[^@/]+@)?(github\.com|gitlab\.com|bitbucket\.org|codeberg\.org)\/(.*)$/.exec(remote);
  return forge ? `https://${forge[1]}/${forge[2]}` : remote;
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

// The helpers the unit tests in tests/unit.test.cjs exercise. Yarn reads
// only `name` and `factory`.
module.exports.internals = {
  urlPath,
  fetchUrl,
  registryMirrors,
  stableUrl,
  isGithubArchive,
  canonical,
  contentHash,
  readLock,
  writeLock,
};
