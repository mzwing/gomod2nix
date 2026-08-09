# Getting started with Gomod2nix

## Installation

### Using Niv

First initialize Niv:
``` bash
$ niv init --latest
$ niv add nix-community/gomod2nix
```

Create a `shell.nix` used for development:
``` nix
{ pkgs ? (
    let
      sources = import ./nix/sources.nix;
    in
    import sources.nixpkgs {
      overlays = [
        (import "${sources.gomod2nix}/overlay.nix")
      ];
    }
  )
}:

let
  goEnv = pkgs.mkGoEnv { pwd = ./.; };
in
pkgs.mkShell {
  packages = [
    goEnv
    pkgs.gomod2nix
    pkgs.niv
  ];
}
```

And a `default.nix` for building your package
``` nix
{ pkgs ? (
    let
      sources = import ./nix/sources.nix;
    in
    import sources.nixpkgs {
      overlays = [
        (import "${sources.gomod2nix}/overlay.nix")
      ];
    }
  )
}:

pkgs.buildGoApplication {
  pname = "myapp";
  version = "0.1";
  pwd = ./.;
  src = ./.;
  modules = ./gomod2nix.toml;
}
```

### Using Flakes

The quickest way to get started if using Nix Flakes is to use the Flake template:
``` bash
$ nix flake init -t github:nix-community/gomod2nix#app
```
It is also possible to use the container template to build container images:
```bash
$ nix flake init -t github:nix-community/gomod2nix#container
```

## Basic usage

After you have entered your development shell you can generate a `gomod2nix.toml` using:
``` bash
$ gomod2nix generate
```

To optimize build performance by pre-compiling dependencies in the build cache, use:
``` bash
$ gomod2nix generate --with-deps
```

This generates a `cacheModules` section describing every external Go module's packages and their module-level dependency edges. During the build, each module is pre-compiled into its own cache derivation (forming a DAG that mirrors the import graph), and the final build restores all of them plus a shared standard-library cache. Changing your own source code never rebuilds dependency caches; adding or bumping a dependency only rebuilds that module's cache and its reverse dependencies. Module caches are keyed only by the module sources, versions, toolchain and build flags, so two projects resolving the same dependency versions share the same cache store paths (also via a binary cache).

Note that `--with-deps` requires regenerating `gomod2nix.toml` (schema version 4). Older `gomod2nix.toml` files carrying a flat `cachePackages` list still work and fall back to the previous monolithic cache behavior.

To speed up development and avoid downloading dependencies again in the Nix store you can import them directly from the Go cache using:
``` bash
$ gomod2nix import
```
