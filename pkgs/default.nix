# SPDX-License-Identifier: MIT
{ callPackage, ... }:
let
  plugin = callPackage ./plugin { };
in
{
  # The Yarn plugin, with this flake's Nix library filled in.
  inherit plugin;
  # Yarn Berry with the plugin loaded.
  yarn = callPackage ./yarn { inherit plugin; };
}
