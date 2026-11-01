# SPDX-License-Identifier: MIT
#
# The Yarn plugin (plugin/purifier.cjs), with the store paths of this
# flake's Nix library and of nixpkgs filled in. Interactive use builds the
# project's downloads through that library.
{
  runCommand,
  path,
}:
runCommand "yarn-berry-purifier-plugin.cjs" { } ''
  substitute ${../../plugin/purifier.cjs} "$out" \
    --replace-fail '@nixLib@' ${../../nix/lib} \
    --replace-fail '@nixpkgs@' ${path}
''
