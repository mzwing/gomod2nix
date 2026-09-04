# Gomod2nix Nix API

## Public functions

### buildGoApplication

Arguments:

- **modules** Path to `gomod2nix.toml` (\_default: `pwd + "/gomod2nix.toml"`).
- **src** Path to sources (\_default: `pwd`).
- **pwd** Path to working directory (\_default: `null`).
- **go** The Go compiler to use (can be omitted, see [Go toolchain selection](#go-toolchain-selection)).
- **subPackages** Only build these specific sub packages.
- **allowGoReference** Allow references to the Go compiler in the output closure (\_default: `false`).
- **tags** A list of tags to pass the Go compiler during the build (\_default: `[ ]`).
- **ldflags** A list of `ldflags` to pass the Go compiler during the build (\_default: `[ ]`).
- **disableGoCache** Disable the dependency build cache entirely (\_default: `false`).
- **goModuleProxy** Module proxy (`GOPROXY`) used by the fixed-output module fetchers, e.g. a `file://` proxy for fully offline builds. Disables the checksum database for the fetches when set (\_default: `null`, use the ambient/default proxy configuration).
- **nativeBuildInputs** A list of packages to include in the build derivation (\_default: `[ ]`).

All other arguments are passed verbatim to `stdenv.mkDerivation`.

#### Per-module build cache

When `gomod2nix.toml` is generated with `gomod2nix generate --with-deps`
(schema version 4), it carries a `cacheModules` section mapping every
external Go module to its packages and module-level dependency edges
(derived from actual package imports, hence acyclic).
`buildGoApplication` then creates one cache derivation per module:

- Each module gets an isolated build context: a vendor tree containing
  only its transitive dependency closure plus a synthetic `go.mod`.
  Contexts depend only on module sources/versions and the Go toolchain -
  never on the project's `go.mod`/`go.sum` - so identical closures produce
  identical store paths across projects.
- Every module cache derivation restores a shared standard-library cache
  (one per toolchain/GOOS/GOARCH/CGO/tags configuration) plus the caches
  of its dependency modules, compiles only its own packages, and archives
  only the cache entries it created. GOCACHE is content-addressed, so
  merging archives by extraction is a safe union operation.
- The final build restores the std cache and all module caches and only
  compiles the project's own packages.

Invalidation behavior: editing your own sources rebuilds only the final
derivation; adding or bumping a dependency rebuilds only that module's
cache and its reverse dependencies. Modules replaced with a local path
(and modules importing them) are excluded from caching and are compiled in
the final build, as before.

Useful `passthru` attributes for debugging or pushing to a binary cache:

- **goModuleCacheEnvs** Attrset mapping module path -> cache derivation.
- **goStdCacheEnv** The shared standard-library cache derivation.
- **goCacheEnv** The legacy monolithic cache derivation (only set for
  `gomod2nix.toml` files that carry a flat `cachePackages` list, i.e.
  schema <= 3).

Legacy `gomod2nix.toml` files (schema <= 3, flat `cachePackages` list)
continue to use the previous monolithic cache derivation. A
`gomod2nix.toml` with neither section builds no cache derivation at all.

#### Go toolchain selection

When **go** is not passed, the compiler is chosen from the version in the
project's `go` directive: the nixpkgs default `go` if it already satisfies
that version, otherwise the newest `go_*` attribute that does. A module
requiring a Go newer than anything in nixpkgs is an evaluation error rather
than a build that tries to download a toolchain it cannot reach from the
sandbox.

The directive is read from `go.mod` when **pwd** is passed. For a fetched
**src** there is no `go.mod` to read at evaluation time, so the generator
records the same version as a top-level `go` key in `gomod2nix.toml`.
Files generated before that key existed simply get the default `go`.

### mkGoEnv

Arguments:

- **pwd** Path to working directory.
- **modules** Path to `gomod2nix.toml` (\_default: `pwd + "/gomod2nix.toml"`).
- **toolsGo** Path to `tools.go` (\_default: `pwd + "/tools.go"`).
- **goModuleProxy** Module proxy (`GOPROXY`) used by the fixed-output module fetchers, e.g. a `file://` proxy for fully offline builds (\_default: `null`).

All other arguments are passed verbatim to `stdenv.mkDerivation`.
