# SPDX-License-Identifier: MIT
#
# The fetched downloads of a lock, laid out as a tree: each download's file
# lies at its `path`, as a link to its fixed-output fetch. The plugin
# answers each of Yarn's requests with the file at the request URL's path in
# this tree.
#
# This file knows nothing of Yarn: it takes download entries of the shape
# { path, url, mirrors, hash }, where `mirrors` lists other URLs that serve
# the same file and `hash` is the SRI hash of the file.
{
  lib,
  runCommand,
  fetchurl,
  # The download entries.
  downloads,
  # The name of the tree in the store.
  name ? "yarn-berry-purifier-dependencies",
}:
let
  # A store name allows fewer characters than a URL; the last segment of
  # the URL, with the rest replaced, keeps the store listing readable.
  storeName =
    url:
    let
      base = lib.last (lib.splitString "/" (builtins.head (lib.splitString "?" url)));
      clean = builtins.replaceStrings [ "%" "@" "~" "!" ":" ] [ "_" "_" "_" "_" "_" ] base;
    in
    if clean == "" then "download" else clean;

  fetch =
    d:
    fetchurl {
      urls = [ d.url ] ++ d.mirrors;
      inherit (d) hash;
      name = storeName d.url;
    };
in
runCommand name
  {
    # The tree holds only links.
    preferLocalBuild = true;
    allowSubstitutes = false;
    passAsFile = [ "links" ];
    links = lib.concatMapStrings (d: "${d.path}\t${fetch d}\n") downloads;
  }
  ''
    mkdir -p "$out"
    while IFS=$'\t' read -r path target; do
      mkdir -p "$out/$(dirname "$path")"
      ln -s "$target" "$out/$path"
    done < "$linksPath"
  ''
