// SPDX-License-Identifier: MIT
//
// The downloads of git and GitHub dependencies whose repositories Yarn
// packs with npm or with Yarn Classic. Yarn picks the package manager of
// such a repository by its package.json `packageManager` field and its
// lockfile, and runs that package manager in the repository, where Yarn's
// network hook sees none of its downloads. The repository's own lockfile
// names them: a package-lock.json with each tarball's URL and integrity,
// or a Yarn Classic yarn.lock. This module reads those lockfiles and lays
// the tarballs out where each package manager finds them offline:
//
//   npm-cache/_cacache/content-v2/<algorithm>/<hex>  npm's cache, which npm
//                                                    reads by integrity
//   yarn-mirror/<file>                               a Yarn Classic offline
//                                                    mirror

const crypto = require("crypto");
const zlib = require("zlib");

// The Nix systems as npm's os and cpu names.
const NPM_PLATFORMS = {
  "x86_64-linux": { os: "linux", cpu: "x64" },
  "aarch64-linux": { os: "linux", cpu: "arm64" },
  "x86_64-darwin": { os: "darwin", cpu: "x64" },
  "aarch64-darwin": { os: "darwin", cpu: "arm64" },
};

// npm's rule for the os and cpu fields: a name that is listed allows, a
// name listed with a leading "!" forbids, and a list of only forbidden names
// allows the rest.
function allows(value, list) {
  if (!list || list.length === 0) return true;
  if (list.includes(`!${value}`)) return false;
  const allowed = list.filter((x) => !x.startsWith("!"));
  return allowed.length === 0 || allowed.includes(value);
}

function strongest(integrity) {
  const rank = (h) => (h.startsWith("sha512-") ? 3 : h.startsWith("sha384-") ? 2 : h.startsWith("sha256-") ? 1 : 0);
  return integrity
    .split(/\s+/)
    .filter((h) => h !== "")
    .sort((a, b) => rank(b) - rank(a))[0];
}

function contentPath(sri) {
  const [algorithm, base64] = [sri.slice(0, sri.indexOf("-")), sri.slice(sri.indexOf("-") + 1)];
  const hex = Buffer.from(base64, "base64").toString("hex");
  return `npm-cache/_cacache/content-v2/${algorithm}/${hex.slice(0, 2)}/${hex.slice(2, 4)}/${hex.slice(4)}`;
}

// The downloads that `npm install` makes from a package-lock.json
// (lockfileVersion 2 or 3, and 1 through its `dependencies`), each with the
// systems npm installs it on.
function npmDownloads(text, systems) {
  const lock = JSON.parse(text);
  const entries = [];
  if (lock.packages) {
    for (const [key, entry] of Object.entries(lock.packages)) {
      if (key === "" || entry.link || entry.inBundle) continue;
      entries.push(entry);
    }
  } else {
    const walk = (deps) => {
      for (const entry of Object.values(deps || {})) {
        if (!entry.bundled) entries.push(entry);
        walk(entry.dependencies);
      }
    };
    walk(lock.dependencies);
  }
  const downloads = [];
  for (const entry of entries) {
    if (!entry.resolved || !/^https?:/.test(entry.resolved) || !entry.integrity) continue;
    const hash = strongest(entry.integrity);
    const on = systems.filter((system) => {
      const p = NPM_PLATFORMS[system];
      return !entry.optional || (allows(p.os, entry.os) && allows(p.cpu, entry.cpu));
    });
    if (on.length === 0) continue;
    downloads.push({ path: contentPath(hash), url: entry.resolved, hash, systems: on });
  }
  return downloads;
}

// The name Yarn Classic gives a tarball in its offline mirror
// (RE_URL_NAME_MATCH in Yarn Classic's source).
function classicMirrorName(url) {
  const pathname = new URL(url).pathname;
  const m = /\/(?:(@[^/]+)(?:\/|%2f))?[^/]+\/(?:-|_attachments)\/(?:@[^/]+\/)?([^/]+)$/.exec(pathname);
  if (m) return m[1] ? `${m[1]}-${m[2]}` : m[2];
  return pathname.slice(pathname.lastIndexOf("/") + 1);
}

// The downloads that Yarn Classic makes from its yarn.lock: one block per
// entry, a blank line between blocks, and the fields indented by two
// spaces. Yarn Classic fetches every package, whatever the platform.
function classicDownloads(text, systems) {
  const downloads = [];
  for (const block of text.split("\n\n")) {
    const field = (name) => {
      const m = new RegExp(`^  ${name} "?([^"\\n]*)"?$`, "m").exec(block);
      return m ? m[1] : null;
    };
    const resolved = field("resolved");
    if (!resolved || !/^https?:/.test(resolved)) continue;
    const [url, fragment] = resolved.split("#");
    const integrity = field("integrity");
    let hash = null;
    if (integrity) hash = strongest(integrity);
    else if (fragment && /^[0-9a-f]{40}$/.test(fragment)) {
      hash = `sha1-${Buffer.from(fragment, "hex").toString("base64")}`;
    }
    if (!hash) {
      throw new Error(`yarn-berry-purifier: ${url} in a Yarn Classic yarn.lock of a git dependency carries no hash`);
    }
    downloads.push({ path: `yarn-mirror/${classicMirrorName(url)}`, url, hash, systems: [...systems] });
  }
  return downloads;
}

// The downloads of a repository, given the text of its package.json and
// of its lockfiles, as Yarn would pick the package manager.
function foreignDownloads({ manifest, npmLock, yarnLock }, systems) {
  let packageManager = null;
  try {
    packageManager = JSON.parse(manifest).packageManager || null;
  } catch {}
  const name = packageManager ? packageManager.split("@")[0] : null;
  const major = packageManager ? Number(packageManager.split("@")[1]?.split(".")[0]) : null;
  if (name === "npm" || (!name && yarnLock === null && npmLock !== null)) {
    return npmLock === null ? null : npmDownloads(npmLock, systems);
  }
  if ((name === "yarn" && major === 1) || (!name && yarnLock !== null && !/^__metadata:$/m.test(yarnLock))) {
    return yarnLock === null ? null : classicDownloads(yarnLock, systems);
  }
  return [];
}

// The top-level files of a .tar.gz, such as a GitHub archive, whose
// entries all lie in one directory. It returns the files named in `names`
// that lie directly in that directory, as buffers.
function topLevelFiles(tarGz, names) {
  const tar = zlib.gunzipSync(tarGz);
  const found = {};
  let longName = null;
  let paxPath = null;
  for (let offset = 0; offset + 512 <= tar.length; ) {
    const header = tar.subarray(offset, offset + 512);
    if (header.every((b) => b === 0)) break;
    const field = (start, length) => header.subarray(start, start + length).toString("utf8").replace(/\0.*$/s, "");
    const size = parseInt(field(124, 12).trim() || "0", 8);
    const type = String.fromCharCode(header[156]);
    const body = tar.subarray(offset + 512, offset + 512 + size);
    offset += 512 + Math.ceil(size / 512) * 512;
    if (type === "L") {
      longName = body.toString("utf8").replace(/\0.*$/s, "");
      continue;
    }
    if (type === "x") {
      const m = /\d+ path=([^\n]*)\n/.exec(body.toString("utf8"));
      paxPath = m ? m[1] : null;
      continue;
    }
    if (type === "g") continue;
    const prefix = field(345, 155);
    const name = longName || paxPath || (prefix ? `${prefix}/${field(0, 100)}` : field(0, 100));
    longName = null;
    paxPath = null;
    const parts = name.split("/").filter((p) => p !== "");
    if (parts.length === 2 && names.includes(parts[1]) && (type === "0" || type === "\0")) {
      found[parts[1]] = Buffer.from(body);
    }
  }
  return found;
}

function manifestHash(manifest) {
  return crypto.createHash("sha256").update(manifest).digest("hex");
}

module.exports = {
  foreignDownloads,
  npmDownloads,
  classicDownloads,
  classicMirrorName,
  topLevelFiles,
  manifestHash,
  NPM_PLATFORMS,
};
