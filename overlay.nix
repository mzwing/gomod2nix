final: prev: {
  inherit
    (final.callPackage ./builder {})
    buildGoApplication
    mkGoEnv
    mkGoCacheEnv
    hooks
    ;
  gomod2nix = final.callPackage ./default.nix {};
}
