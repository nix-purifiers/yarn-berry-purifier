# SPDX-License-Identifier: MIT
#
# The `yarn-berry-purifier` library namespace. It holds nothing: the
# builder needs a package set, so it is the package
# `buildYarnBerryProject` that the default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    yarn-berry-purifier = prev.yarn-berry-purifier or { };
  };

}
