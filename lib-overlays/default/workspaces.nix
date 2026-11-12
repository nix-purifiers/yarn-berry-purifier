# SPDX-License-Identifier: MIT
#
# The project's own packages, read from its package.json files at evaluation
# time: the root, and the workspaces that the root's `workspaces` field
# names. It returns them by package name, as { name, version, dir, bin }:
# `dir` is the package's directory relative to the project root ("" for the
# root), and `bin` maps each command name to its file. A root that declares
# workspaces is a package only when it has commands, because such a root
# usually only coordinates its workspaces.
#
# Yarn reads `workspaces` as a list of glob patterns, or as an attribute set
# whose `packages` holds that list. The patterns here may use `*` within a
# path segment and `**` for any number of segments; a pattern with a leading
# `!` excludes the directories it matches.
{
  lib,
  # The project root.
  src,
}:
let
  readManifest = dir: lib.importJSON (src + "/${dir}/package.json");
  root = readManifest "";

  patterns =
    let
      w = root.workspaces or [ ];
    in
    if builtins.isList w then w else w.packages or [ ];

  # A glob segment as a regular expression for builtins.match.
  segmentRegex =
    segment:
    lib.concatMapStrings (
      c:
      if c == "*" then
        "[^/]*"
      else if c == "?" then
        "[^/]"
      else if
        lib.elem c [
          "."
          "+"
          "("
          ")"
          "["
          "]"
          "{"
          "}"
          "^"
          "$"
          "|"
          "\\"
        ]
      then
        "\\${c}"
      else
        c
    ) (lib.stringToCharacters segment);

  subdirs =
    dir:
    let
      entries = builtins.readDir (src + "/${dir}");
    in
    builtins.filter (name: entries.${name} == "directory" && name != "node_modules") (
      builtins.attrNames entries
    );

  join = dir: name: if dir == "" then name else "${dir}/${name}";

  # The directories under `dir` that the pattern segments match.
  expand =
    dir: segments:
    if segments == [ ] then
      [ dir ]
    else
      let
        segment = builtins.head segments;
        rest = builtins.tail segments;
      in
      if segment == "" || segment == "." then
        expand dir rest
      else if segment == "**" then
        expand dir rest ++ lib.concatMap (name: expand (join dir name) segments) (subdirs dir)
      else if lib.hasInfix "*" segment || lib.hasInfix "?" segment then
        lib.concatMap (name: expand (join dir name) rest) (
          builtins.filter (name: builtins.match (segmentRegex segment) name != null) (subdirs dir)
        )
      else if builtins.pathExists (src + "/${join dir segment}") then
        expand (join dir segment) rest
      else
        [ ];

  matches = pattern: expand "" (lib.splitString "/" (lib.removePrefix "./" pattern));

  included = lib.unique (lib.concatMap matches (builtins.filter (p: !lib.hasPrefix "!" p) patterns));
  excluded = lib.concatMap (p: matches (lib.removePrefix "!" p)) (
    builtins.filter (p: lib.hasPrefix "!" p) patterns
  );
  workspaceDirs = builtins.filter (
    dir: !(lib.elem dir excluded) && builtins.pathExists (src + "/${dir}/package.json")
  ) included;

  binOf =
    manifest:
    let
      bin = manifest.bin or { };
    in
    if builtins.isString bin then { ${lib.last (lib.splitString "/" manifest.name)} = bin; } else bin;

  package =
    dir:
    let
      manifest = readManifest dir;
    in
    {
      inherit (manifest) name;
      version = manifest.version or "0.0.0";
      inherit dir;
      bin = binOf manifest;
    };

  rootIsPackage = root ? name && !(patterns != [ ] && binOf root == { });
  dirs = lib.optional rootIsPackage "" ++ workspaceDirs;
in
lib.listToAttrs (
  map (
    dir:
    let
      p = package dir;
    in
    lib.nameValuePair p.name p
  ) (builtins.filter (dir: (readManifest dir) ? name) dirs)
)
