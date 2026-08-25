final: prev: {
  inherit
    (final.callPackage ./builder {})
    buildGoApplication
    mkGoEnv
    hooks
    ;
  gomod2nix = final.callPackage ./default.nix {};
}
