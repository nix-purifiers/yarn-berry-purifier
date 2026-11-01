#!/usr/bin/env node
console.log(
  [
    require("@sources/words"),
    require("left-pad")("github", 7, "."),
    require("is-odd/patched.js"),
    require("portal-dependency"),
    require("link-dependency"),
    require("file-dependency"),
    require("file-tarball"),
  ].join(" "),
);
