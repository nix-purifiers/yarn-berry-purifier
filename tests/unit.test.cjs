// SPDX-License-Identifier: MIT
//
// Unit tests of the plugin's URL handling and of its readers of the
// lockfiles of npm and Yarn Classic. `node --test` runs them; the plugin
// directory comes from the environment variable PLUGIN.

const assert = require("node:assert/strict");
const test = require("node:test");
const zlib = require("node:zlib");
const path = require("node:path");

const plugin = require(path.join(process.env.PLUGIN, "purifier.cjs"));
const foreign = require(path.join(process.env.PLUGIN, "foreign.cjs"));
const { urlPath, fetchUrl, registryMirrors, stableUrl, isGithubArchive } = plugin.internals;

const SYSTEMS = ["x86_64-linux", "aarch64-linux", "x86_64-darwin", "aarch64-darwin"];
const INTEGRITY = "sha512-dKlgKLTrnih8yfGKBozBsVcGe0mS1/aKhCGPevK47XUNBMB+L0qk6zFw3YQnOFqH8dWqP9KNw9V+g1oOw4ew2g==";

test("urlPath puts the scheme, host and path in the tree", () => {
  assert.equal(
    urlPath("https://registry.yarnpkg.com/@babel%2fcore/-/core-7.0.0.tgz"),
    "https/registry.yarnpkg.com/@babel%2fcore/-/core-7.0.0.tgz",
  );
});

test("urlPath encodes the query into the last segment", () => {
  assert.equal(urlPath("https://example.com/a.tgz?token=1&x=2"), "https/example.com/a.tgz%3Ftoken%3D1%26x%3D2");
});

test("urlPath names a directory URL index", () => {
  assert.equal(urlPath("https://repo.yarnpkg.com/"), "https/repo.yarnpkg.com/index");
});

test("urlPath keeps the port in the host", () => {
  assert.equal(urlPath("http://127.0.0.1:4873/a/-/a-1.0.0.tgz"), "http/127.0.0.1:4873/a/-/a-1.0.0.tgz");
});

test("fetchUrl turns the ssh URL of a public forge into https", () => {
  assert.equal(fetchUrl("ssh://git@gitlab.com/group/repo.git"), "https://gitlab.com/group/repo.git");
  assert.equal(fetchUrl("ssh://git@git.example.com/repo.git"), "ssh://git@git.example.com/repo.git");
  assert.equal(fetchUrl("https://codeberg.org/a/b.git"), "https://codeberg.org/a/b.git");
});

test("registryMirrors pairs the Yarn registry with the npm registry", () => {
  assert.deepEqual(registryMirrors("https://registry.yarnpkg.com/a/-/a-1.0.0.tgz"), [
    "https://registry.npmjs.org/a/-/a-1.0.0.tgz",
  ]);
  assert.deepEqual(registryMirrors("https://registry.npmjs.org/a/-/a-1.0.0.tgz"), [
    "https://registry.yarnpkg.com/a/-/a-1.0.0.tgz",
  ]);
  assert.deepEqual(registryMirrors("https://example.com/a.tgz"), []);
});

test("stableUrl maps Yarn Classic's latest.js to the GitHub release of its version", () => {
  const body = Buffer.from('x({"name":"yarn","installationMethod":"unknown","version":"1.22.22","license":"BSD"})');
  assert.equal(
    stableUrl("https://classic.yarnpkg.com/latest.js", body),
    "https://github.com/yarnpkg/yarn/releases/download/v1.22.22/yarn-1.22.22.js",
  );
  assert.equal(stableUrl("https://example.com/latest.js", body), null);
});

test("isGithubArchive recognizes GitHub archives", () => {
  assert.equal(isGithubArchive("https://github.com/o/r/archive/abc.tar.gz"), true);
  assert.equal(isGithubArchive("https://codeload.github.com/o/r/tar.gz/abc"), true);
  assert.equal(isGithubArchive("https://registry.yarnpkg.com/a/-/a-1.0.0.tgz"), false);
});

test("classicMirrorName follows the mirror names of Yarn Classic", () => {
  assert.equal(foreign.classicMirrorName("https://registry.yarnpkg.com/lodash/-/lodash-4.17.21.tgz"), "lodash-4.17.21.tgz");
  assert.equal(
    foreign.classicMirrorName("https://registry.yarnpkg.com/@babel/core/-/core-7.0.0.tgz"),
    "@babel-core-7.0.0.tgz",
  );
  assert.equal(
    foreign.classicMirrorName("https://registry.example.com/@scope%2fname/-/name-1.0.0.tgz"),
    "@scope-name-1.0.0.tgz",
  );
  assert.equal(foreign.classicMirrorName("https://example.com/files/other.tgz?x=1"), "other.tgz");
});

test("npmDownloads keeps optional packages only on the systems they allow", () => {
  const lock = JSON.stringify({
    lockfileVersion: 3,
    packages: {
      "": { name: "p" },
      "node_modules/a": { resolved: "https://registry.npmjs.org/a/-/a-1.0.0.tgz", integrity: INTEGRITY },
      "node_modules/@esbuild/linux-arm64": {
        resolved: "https://registry.npmjs.org/@esbuild/linux-arm64/-/linux-arm64-0.25.0.tgz",
        integrity: INTEGRITY,
        optional: true,
        os: ["linux"],
        cpu: ["arm64"],
      },
      "node_modules/linked": { link: true, resolved: "packages/linked" },
    },
  });
  const downloads = foreign.npmDownloads(lock, SYSTEMS);
  assert.equal(downloads.length, 2);
  assert.deepEqual(downloads[0].systems, SYSTEMS);
  assert.deepEqual(downloads[1].systems, ["aarch64-linux"]);
  assert.match(downloads[0].path, /^npm-cache\/_cacache\/content-v2\/sha512\/74\/a9\//);
});

test("classicDownloads takes the integrity, or the SHA-1 of the fragment", () => {
  const text = [
    "# yarn lockfile v1",
    "",
    "",
    'a@^1.0.0:\n  version "1.0.0"\n  resolved "https://registry.yarnpkg.com/a/-/a-1.0.0.tgz#679591c564c3bffaae8454cf0b3df370c3d6911c"\n  integrity ' +
      INTEGRITY,
    "",
    'b@^1.0.0:\n  version "1.0.0"\n  resolved "https://registry.yarnpkg.com/b/-/b-1.0.0.tgz#679591c564c3bffaae8454cf0b3df370c3d6911c"',
  ].join("\n");
  const downloads = foreign.classicDownloads(text, SYSTEMS);
  assert.deepEqual(
    downloads.map((d) => [d.path, d.hash]),
    [
      ["yarn-mirror/a-1.0.0.tgz", INTEGRITY],
      ["yarn-mirror/b-1.0.0.tgz", "sha1-Z5WRxWTDv/quhFTPCz3zcMPWkRw="],
    ],
  );
});

test("classicDownloads rejects a tarball without a hash", () => {
  const text = 'a@^1.0.0:\n  version "1.0.0"\n  resolved "https://example.com/a.tgz"';
  assert.throws(() => foreign.classicDownloads(text, SYSTEMS), /carries no hash/);
});

test("foreignDownloads picks the package manager as Yarn does", () => {
  const npmLock = JSON.stringify({ lockfileVersion: 3, packages: { "": {} } });
  assert.deepEqual(foreign.foreignDownloads({ manifest: "{}", npmLock, yarnLock: null }, SYSTEMS), []);
  assert.equal(
    foreign.foreignDownloads({ manifest: '{"packageManager":"npm@10.0.0"}', npmLock: null, yarnLock: null }, SYSTEMS),
    null,
  );
  assert.equal(
    foreign.foreignDownloads({ manifest: '{"packageManager":"yarn@1.22.22"}', npmLock: null, yarnLock: null }, SYSTEMS),
    null,
  );
  assert.deepEqual(
    foreign.foreignDownloads({ manifest: "{}", npmLock: null, yarnLock: "__metadata:\n  version: 8\n" }, SYSTEMS),
    [],
  );
});

// A .tar.gz with the given files below one top-level directory, as GitHub
// archives are laid out.
function tarGz(files) {
  const blocks = [];
  for (const [name, content] of Object.entries(files)) {
    const body = Buffer.from(content);
    const header = Buffer.alloc(512);
    header.write(name, 0);
    header.write("0000644\0", 100);
    header.write("0000000\0", 108);
    header.write("0000000\0", 116);
    header.write(`${body.length.toString(8).padStart(11, "0")}\0`, 124);
    header.write("00000000000\0", 136);
    header.write("        ", 148);
    header.write("0", 156);
    header.write("ustar\0", 257);
    header.write("00", 263);
    let sum = 0;
    for (const b of header) sum += b;
    header.write(`${sum.toString(8).padStart(6, "0")}\0 `, 148);
    blocks.push(header, body, Buffer.alloc((512 - (body.length % 512)) % 512));
  }
  blocks.push(Buffer.alloc(1024));
  return zlib.gzipSync(Buffer.concat(blocks));
}

test("topLevelFiles reads the files at the top of an archive", () => {
  const archive = tarGz({
    "repo-abc/package.json": '{"name":"repo"}',
    "repo-abc/yarn.lock": "# yarn lockfile v1\n",
    "repo-abc/sub/package.json": '{"name":"nested"}',
  });
  const files = foreign.topLevelFiles(archive, ["package.json", "package-lock.json", "yarn.lock"]);
  assert.equal(files["package.json"].toString(), '{"name":"repo"}');
  assert.equal(files["yarn.lock"].toString(), "# yarn lockfile v1\n");
  assert.equal(files["package-lock.json"], undefined);
});
