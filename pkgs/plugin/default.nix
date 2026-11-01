# SPDX-License-Identifier: MIT
#
# The Yarn plugin (plugin/), with the store paths of this flake's Nix
# library and of nixpkgs filled in. Interactive use builds the project's
# downloads through that library. Yarn loads the plugin from
# purifier.cjs, which requires the files beside it.
{
  runCommand,
  path,
}:
runCommand "yarn-berry-purifier-plugin" { } ''
  mkdir -p "$out"
  cp ${../../plugin/foreign.cjs} "$out/foreign.cjs"
  substitute ${../../plugin/purifier.cjs} "$out/purifier.cjs" \
    --replace-fail '@nixLib@' ${../../nix/lib} \
    --replace-fail '@nixpkgs@' ${path} \
    --replace-fail '@flake@' ${../..}
''
