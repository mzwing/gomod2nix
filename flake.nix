{
  description = "Convert go.mod/go.sum to Nix packages";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = [
      "aarch64-linux"
      "aarch64-darwin"
      # x86_64-darwin: dropped by nixpkgs 26.11
      "x86_64-linux"
      "riscv64-linux"
    ];

    forAllSystems = f:
      nixpkgs.lib.genAttrs systems (
        system: f system nixpkgs.legacyPackages.${system}
      );

    perSystem = forAllSystems (
      _: pkgs: let
        lib = pkgs.lib;

        callPackage = pkgs.callPackage;

        inherit
          (callPackage ./builder {
            inherit gomod2nix;
          })
          mkGoEnv
          buildGoApplication
          hooks
          ;
        gomod2nix = callPackage ./default.nix {
          inherit
            buildGoApplication
            mkGoEnv
            hooks
            ;
        };

        # golangci-lint check. The module dependencies come from the
        # vendor tree of the gomod2nix build itself (fixed-output
        # derivations), so the check runs fully offline in the sandbox.
        lintCheck = pkgs.stdenv.mkDerivation {
          name = "gomod2nix-lint-check";

          # See fmtSrc: keep the module sources only, not untracked
          # working-tree junk.
          src = lib.cleanSourceWith {
            src = ./.;
            filter = path: type: let
              baseName = baseNameOf path;
            in
              (type == "directory" && !(builtins.elem baseName [".direnv"]))
              || lib.hasSuffix ".go" path
              || baseName == "go.mod"
              || baseName == "go.sum";
          };

          nativeBuildInputs = [
            pkgs.golangci-lint
            gomod2nix.passthru.go
            gomod2nix.passthru.hooks.goConfigHook
          ];

          goVendorDir = gomod2nix.passthru.vendorEnv;

          # goConfigHook (postPatch) sets up the vendor directory and the
          # offline Go environment (GOPROXY=off, GOFLAGS=-mod=vendor, ...).
          buildPhase = ''
            runHook preBuild

            export HOME="$TMPDIR/home"
            export GOLANGCI_LINT_CACHE="$TMPDIR/golangci-lint-cache"
            mkdir -p "$HOME" "$GOLANGCI_LINT_CACHE"

            golangci-lint run

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            touch $out
            runHook postInstall
          '';
        };

        # Freshness check for the root gomod2nix.toml, fully evaluated at
        # instantiation time: the module set and versions recorded in the
        # toml must match the require directives of the root go.mod
        # (hash correctness itself is enforced by the fixed-output module
        # fetchers at build time). Modules replaced with a local path are
        # never recorded in the toml and are excluded from the comparison.
        tomlFreshnessCheck = let
          parseGoMod = import ./builder/parser.nix;
          goMod = parseGoMod (builtins.readFile ./go.mod);
          modulesStruct = builtins.fromTOML (builtins.readFile ./gomod2nix.toml);

          localReplaced = lib.filterAttrs (_: v: v ? path) goMod.replace;

          expected =
            lib.filterAttrs (name: _: !(builtins.hasAttr name localReplaced))
            goMod.require;

          # The version recorded for a replaced module is the
          # replacement's version.
          expectedVersion = name:
            if
              builtins.hasAttr name goMod.replace
              && goMod.replace.${name} ? version
            then goMod.replace.${name}.version
            else expected.${name};

          actual = modulesStruct.mod or {};

          recordedGo = modulesStruct.go or null;
          expectedGo = goMod.go or null;

          missing = lib.filter (name: !(builtins.hasAttr name actual)) (
            builtins.attrNames expected
          );
          extra = lib.filter (name: !(builtins.hasAttr name expected)) (
            builtins.attrNames actual
          );
          mismatched = lib.filter (
            name:
              builtins.hasAttr name actual
              && (actual.${name}.version or null) != expectedVersion name
          ) (builtins.attrNames expected);

          report = ''
            gomod2nix.toml is out of date with go.mod.
            missing modules: ${toString missing}
            extra modules: ${toString extra}
            version mismatches: ${toString mismatched}
            go directive: recorded "${toString recordedGo}", go.mod says "${toString expectedGo}"
            Regenerate it with: gomod2nix
          '';
        in
          assert lib.assertMsg (missing == [] && extra == [] && mismatched == [] && recordedGo == expectedGo)
          report;
            pkgs.runCommand "gomod2nix-toml-freshness" {} ''
              touch $out
            '';

        # Offline end-to-end tests (see tests/default.nix). Imported
        # directly instead of via callPackage: the file only needs
        # explicitly listed arguments, and callPackage's makeOverridable
        # would leak non-derivation override/overrideDerivation attributes
        # into the flake checks.
        tests = import ./tests {
          inherit
            lib
            gomod2nix
            buildGoApplication
            mkGoEnv
            ;
          inherit (pkgs) runCommand go;
        };
      in {
        packages.default = gomod2nix;
        checks =
          {
            lint = lintCheck;
            toml-freshness = tomlFreshnessCheck;
          }
          // tests;
        legacyPackages = {
          # we cannot put them in packages because they are builder functions
          inherit
            mkGoEnv
            buildGoApplication
            gomod2nix
            hooks
            ;
        };
      }
    );
  in {
    overlays.default = import ./overlay.nix;

    templates = {
      app = {
        path = ./templates/app;
        description = "Gomod2nix packaged application";
      };
      container = {
        path = ./templates/container;
        description = "Gomod2nix packaged container";
      };
      default = self.templates.app;
    };

    packages = builtins.mapAttrs (_: per: per.packages) perSystem;
    checks = builtins.mapAttrs (_: per: per.checks) perSystem;
    legacyPackages = builtins.mapAttrs (_: per: per.legacyPackages) perSystem;

    # No devShells: the development environment is managed by devenv
    # (devenv.nix/devenv.yaml), see .envrc.
  };
}
