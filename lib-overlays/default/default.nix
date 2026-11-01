# SPDX-License-Identifier: MIT
#
# The `yarn-berry-purifier` library namespace: `readLock`
# (nix/lib/read-lock.nix), which reads a project's lockfiles into the lock
# in memory of the purifier contract. It needs no package set.
{ ... }:
{

  overlay = final: prev: {
    yarn-berry-purifier = {
      readLock = import ../../nix/lib/read-lock.nix { lib = final; };
    };
  };

}
