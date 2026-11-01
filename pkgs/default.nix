# SPDX-License-Identifier: MIT
{ callPackage, ... }:
let
  plugin = callPackage ./plugin { };
  yarn = callPackage ./yarn { inherit plugin; };
in
{
  # The Yarn plugin, with this flake's Nix library filled in.
  inherit plugin;
  # Yarn Berry with the plugin loaded.
  inherit yarn;
  # The `yarn-berry-purifier` command: lock, prefetch and publish.
  yarn-berry-purifier = callPackage ./yarn-berry-purifier { inherit yarn; };
}
