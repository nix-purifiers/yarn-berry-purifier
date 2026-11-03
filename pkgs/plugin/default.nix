# SPDX-License-Identifier: MIT
#
# The Yarn plugin (plugin/), with the store paths of this flake's Nix
# library and of nixpkgs filled in. Interactive use builds the project's
# downloads through that library. Yarn loads the plugin from
# purifier.cjs, which requires the files beside it.
{
  runCommand,
  purifier,
  python3,
  path,
}:
let
  # Use the source's content identity consistently across flake imports and
  # the standalone Nix expressions the plugin runs.
  nixpkgsSource = builtins.path {
    inherit path;
    name = "source";
  };
in
runCommand "yarn-berry-purifier-plugin" { } ''
  mkdir -p "$out"
  cp ${../../plugin/foreign.cjs} "$out/foreign.cjs"
  cp ${../../plugin/npm-inputs.cjs} "$out/npm-inputs.cjs"
  cp ${../../plugin/project-inputs.py} "$out/project-inputs.py"
  substitute ${../../plugin/purifier.cjs} "$out/purifier.cjs" \
    --replace-fail '@nixLib@' ${../../nix/lib} \
    --replace-fail '@nixpkgs@' ${nixpkgsSource} \
    --replace-fail '@flake@' ${../..} \
    --replace-fail '@python@' ${python3}/bin/python \
    --replace-fail '@projectInputsTool@' ${purifier.projectInputsTool}
  substitute ${../../plugin/runner.cjs} "$out/runner.cjs" \
    --replace-fail '@python@' ${python3}/bin/python \
    --replace-fail '@projectInputsTool@' ${purifier.projectInputsTool}
''
