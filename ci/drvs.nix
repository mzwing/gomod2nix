# Derivation files (.drv) whose build-time closures form the keep-set of
# the store garbage collection in build.yml ("Garbage-collect stale store
# paths" step, mzwing/nix-config's gc-store-to-build-closure action):
# everything else is collected before the Nix store is saved to the
# GitHub Actions cache, so the saved cache always matches the current
# lock instead of accumulating stale closures from previous locks.
#
# Only instantiates derivations; nothing is built. The end-to-end tests
# are sandboxed flake checks (tests/default.nix), so they are part of the
# flake checks closure.
let
  inherit (builtins) attrValues getFlake;

  system = builtins.currentSystem;

  flake = getFlake "path:${toString ../.}";

  flakeDrvs =
    [flake.packages.${system}.default.drvPath]
    ++ map (drv: drv.drvPath) (attrValues flake.checks.${system});
in
  flakeDrvs
