{
  buildEnv,
  buildPackages,
  cacert,
  fetchgit,
  git,
  gnutar,
  gomod2nix,
  jq,
  lib,
  makeSetupHook,
  pkgsBuildBuild,
  rsync,
  runCommand,
  runtimeShell,
  stdenv,
  stdenvNoCC,
  writeScript,
  zstd,
}: let
  hooks = import ./hooks/default.nix {
    inherit
      lib
      makeSetupHook
      buildPackages
      stdenv
      ;
  };

  inherit
    (hooks)
    goConfigHook
    goBuildHook
    goCheckHook
    goInstallHook
    ;

  inherit
    (builtins)
    elemAt
    hasAttr
    readFile
    split
    substring
    toJSON
    ;
  inherit
    (lib)
    concatStringsSep
    fetchers
    filterAttrs
    mapAttrs
    mapAttrsToList
    optional
    optionalAttrs
    optionalString
    pathExists
    removePrefix
    ;

  parseGoMod = import ./parser.nix;

  # Internal only build-time attributes
  internal = let
    mkInternalPkg = name: src:
      pkgsBuildBuild.runCommand "gomod2nix-${name}"
      {
        inherit (pkgsBuildBuild.go) GOOS GOARCH;
        nativeBuildInputs = [pkgsBuildBuild.go];
      }
      ''
        export HOME=$(mktemp -d)
        go build -o "$HOME/bin" ${src}
        mv "$HOME/bin" "$out"
      '';
  in {
    # Create a symlink tree of vendored sources
    symlink = mkInternalPkg "symlink" ./symlink/symlink.go;

    # Install development dependencies from tools.go
    install = mkInternalPkg "symlink" ./install/install.go;

    # Generate dummy import file for cache warming
    cachegen = mkInternalPkg "cachegen" ./cachegen/cachegen.go;
  };

  fetchGoModule = {
    hash,
    goPackagePath,
    version,
    go,
    # Optional module proxy override (e.g. a file:// proxy for offline
    # builds). When set, the fetcher uses it instead of the ambient
    # GOPROXY and disables the checksum database (which requires
    # network access).
    goModuleProxy ? null,
  }:
    stdenvNoCC.mkDerivation (
      {
        name = "${baseNameOf goPackagePath}_${version}";
        builder = ./fetch.sh;
        inherit goPackagePath version;
        nativeBuildInputs = [
          cacert
          git
          go
          jq
        ];
        outputHashMode = "recursive";
        outputHashAlgo = null;
        outputHash = hash;
        impureEnvVars = fetchers.proxyImpureEnvVars ++ ["GOPROXY"];
      }
      // optionalAttrs (goModuleProxy != null) {
        # Passed as a dedicated variable instead of GOPROXY: the daemon
        # may clobber GOPROXY via impureEnvVars (an unset client GOPROXY
        # would override the value here with the empty string, which Go
        # interprets as "direct"). fetch.sh exports GOPROXY from it.
        inherit goModuleProxy;
      }
    );

  mkVendorEnv = {
    go,
    modulesStruct,
    defaultPackage ? "",
    goMod,
    pwd,
    goModuleProxy ? null,
  }: let
    localReplaceCommands = let
      localReplaceAttrs = filterAttrs (n: v: hasAttr "path" v) goMod.replace;
      commands = (
        mapAttrsToList (name: value: ''
          mkdir -p $(dirname vendor/${name})
          ln -s ${pwd + "/${value.path}"} vendor/${name}
        '')
        localReplaceAttrs
      );
    in
      if goMod != null
      then commands
      else [];

    sources =
      mapAttrs (
        goPackagePath: meta:
          fetchGoModule {
            goPackagePath = meta.replaced or goPackagePath;
            inherit (meta) version hash;
            inherit go goModuleProxy;
          }
      )
      modulesStruct.mod;
  in
    runCommand "vendor-env"
    {
      nativeBuildInputs = [go];
      json = toJSON (filterAttrs (n: _: n != defaultPackage) modulesStruct.mod);

      sources = toJSON (filterAttrs (n: _: n != defaultPackage) sources);

      passthru = {
        inherit sources;
      };

      passAsFile = [
        "json"
        "sources"
      ];
    }
    ''
      mkdir vendor

      export GOCACHE=$TMPDIR/go-cache
      export GOPATH="$TMPDIR/go"

      ${internal.symlink}
      ${concatStringsSep "\n" localReplaceCommands}

      mv vendor $out
    '';

  mkGoCacheEnv = {
    go,
    modulesStruct,
    goMod,
    vendorEnv,
    depFilesPath,
    # Build environment parameters (should match buildGoApplication)
    nativeBuildInputs ? [],
    buildInputs ? [],
    CGO_ENABLED ? go.CGO_ENABLED,
    tags ? [],
    ldflags ? [],
    allowGoReference ? false,
  }: let
    # Check if cachePackages is defined in modulesStruct
    cachePackages = modulesStruct.cachePackages or [];
    hasCachePackages = cachePackages != [];
  in
    stdenv.mkDerivation {
      name = "go-cache-env";

      dontUnpack = true;

      nativeBuildInputs =
        [
          rsync
          go
          goConfigHook
          gnutar
          zstd
        ]
        ++ nativeBuildInputs;

      inherit buildInputs;

      inherit (go) GOOS GOARCH;
      inherit CGO_ENABLED;

      # Pass allowGoReference to hook for GOFLAGS configuration
      allowGoReference =
        if allowGoReference
        then "1"
        else "";

      # Pass tags and ldflags (used by hooks)
      inherit tags ldflags;

      goVendorDir = vendorEnv;

      # Change the working directory in prePatch so GoConfigHook sets up
      # vendor/ at the right location
      prePatch = ''
        # Create a working directory (Go ignores go.mod in /build)
        mkdir -p source
        cd source

        # Copy go.mod and go.sum from filtered source
        cp ${depFilesPath}/go.mod ./go.mod
        cp ${depFilesPath}/go.sum ./go.sum 2>/dev/null || touch go.sum
      '';

      configurePhase = ''
        # Set up GOCACHE directory (will compress to $out later)
        mkdir -p "$GOCACHE"
      '';

      buildPhase = ''
        runHook preBuild

        ${
          if hasCachePackages
          then ''
            echo "Building ${toString (builtins.length cachePackages)} packages to populate cache..."

            # Generate cache.go that imports all packages
            printf '%s\n' ${lib.escapeShellArgs cachePackages} | ${internal.cachegen} > cache.go

            cat cache.go

            # Build cache.go - Go will build all dependencies using its scheduler
            go build -v -mod=vendor cache.go || true

            echo "Cache population complete"
          ''
          else ''
            echo "No cache packages defined, skipping cache population"
          ''
        }

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        echo "Compressing Go build cache..."
        mkdir -p "$out"
        tar -cf - -C "$GOCACHE" . | zstd -T$NIX_BUILD_CORES -o "$out/cache.tar.zst"

        echo "Cache compressed to $out/cache.tar.zst"

        runHook postInstall
      '';
    };

  # Pre-compile the Go standard library into a GOCACHE archive.
  #
  # Since Go 1.20 the standard library is no longer distributed
  # precompiled - it is compiled into GOCACHE on first use. Without this
  # base cache, every per-module cache derivation would compile (and
  # store) its own copy of the std packages it needs, causing massive
  # duplication across the Nix store. All module cache derivations (and
  # the final build) restore this shared base cache instead.
  mkGoStdCacheEnv = {
    go,
    CGO_ENABLED ? go.CGO_ENABLED,
    tags ? [],
    ldflags ? [],
    allowGoReference ? false,
  }: let
    goModText = ''
      module gomod2nix.invalid/std

      go ${lib.versions.majorMinor go.version}
    '';
  in
    stdenv.mkDerivation {
      name = "go-std-cache-${go.version}-${go.GOOS}-${go.GOARCH}";

      dontUnpack = true;

      nativeBuildInputs = [
        go
        goConfigHook
        gnutar
        zstd
      ];

      inherit (go) GOOS GOARCH;
      inherit CGO_ENABLED;

      # Pass allowGoReference to hook for GOFLAGS configuration
      allowGoReference =
        if allowGoReference
        then "1"
        else "";

      # Pass tags and ldflags (used by hooks / buildPhase)
      inherit tags ldflags;

      prePatch = ''
        # Create a working directory with a minimal main module context.
        # The (empty) vendor directory is needed because goConfigHook sets
        # -mod=vendor in GOFLAGS.
        mkdir -p source
        cd source

        printf '%s\n' ${lib.escapeShellArg goModText} > go.mod
        touch go.sum
        mkdir vendor
      '';

      configurePhase = ''
        # Set up GOCACHE directory (will compress to $out later)
        mkdir -p "$GOCACHE"
      '';

      buildPhase = ''
        runHook preBuild

        echo "Building Go standard library to populate cache..."

        go build -v -mod=vendor ''${tags:+-tags=''${tags}} ''${ldflags:+-ldflags="''${ldflags}"} std || true

        echo "Std cache population complete"

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        echo "Compressing Go build cache..."
        mkdir -p "$out"
        tar -cf - -C "$GOCACHE" . | zstd -T$NIX_BUILD_CORES -o "$out/cache.tar.zst"

        echo "Cache compressed to $out/cache.tar.zst"

        runHook postInstall
      '';
    };

  # Create an isolated build context (vendor tree + synthetic go.mod) for a
  # single Go module and its transitive dependency closure.
  #
  # Unlike the project-wide vendorEnv, this context depends only on the
  # closure's module sources (content-addressed FODs), their versions and
  # the Go toolchain - not on the project's go.mod/go.sum. Two projects
  # resolving the same versions for the closure therefore produce the
  # identical store path, which is what makes per-module caches reusable
  # across projects and incrementally rebuildable: adding an unrelated
  # dependency to a project does not change existing module contexts.
  #
  # No modules.txt is generated; vendor consistency checks are disabled
  # via GO_NO_VENDOR_CHECKS=1 in goConfigHook, matching mkVendorEnv.
  mkModuleContext = {
    go,
    modulePath,
    # List of module paths in the transitive closure (incl. modulePath)
    closure,
    modulesStruct,
    # Sources attrset as exposed by mkVendorEnv (vendorEnv.passthru.sources)
    sources,
  }: let
    # Store paths / derivation names cannot contain "/"
    safeName = builtins.replaceStrings ["/"] ["-"] modulePath;

    closureSet = builtins.listToAttrs (
      map (m: {
        name = m;
        value = true;
      })
      closure
    );

    closureMods = filterAttrs (n: _: builtins.hasAttr n closureSet) modulesStruct.mod;
    closureSources = filterAttrs (n: _: builtins.hasAttr n closureSet) sources;

    # Modules fetched through a replace directive are vendored from the
    # replacement source; the synthetic main module only needs a nominal
    # require version since everything is resolved from the vendor tree.
    requireLine = m: meta:
      if meta ? replaced
      then "require ${m} v0.0.0"
      else "require ${m} ${meta.version}";

    goModText = ''
      module gomod2nix.invalid/cache

      go ${lib.versions.majorMinor go.version}

      ${concatStringsSep "\n" (mapAttrsToList requireLine closureMods)}
    '';
  in
    runCommand "mod-context-${safeName}"
    {
      json = toJSON closureMods;
      sources = toJSON closureSources;
      passAsFile = [
        "json"
        "sources"
      ];

      preferLocalBuild = true;
    }
    ''
      mkdir vendor
      ${internal.symlink}

      mkdir -p $out
      mv vendor $out/vendor
      printf '%s\n' ${lib.escapeShellArg goModText} > $out/go.mod
    '';

  # Build the packages of a single Go module into a GOCACHE archive.
  #
  # Caches of this module's dependency modules (depCaches) are restored
  # before building, so only this module's own packages are actually
  # compiled. The output archive contains only cache entries created by
  # this derivation, keeping every per-module cache disjoint so identical
  # dependency artifacts are not duplicated across the Nix store.
  mkModuleCacheEnv = {
    go,
    modulePath,
    version,
    packages,
    depCaches ? [],
    moduleContext,
    # Build environment parameters (should match buildGoApplication)
    nativeBuildInputs ? [],
    buildInputs ? [],
    CGO_ENABLED ? go.CGO_ENABLED,
    tags ? [],
    ldflags ? [],
    allowGoReference ? false,
  }: let
    # Store paths / derivation names cannot contain "/"
    safeName = builtins.replaceStrings ["/"] ["-"] modulePath;
  in
    stdenv.mkDerivation {
      name = "go-cache-${safeName}-${stripVersion version}";

      dontUnpack = true;

      nativeBuildInputs =
        [
          rsync
          go
          goConfigHook
          gnutar
          zstd
        ]
        ++ nativeBuildInputs;

      inherit buildInputs;

      inherit (go) GOOS GOARCH;
      inherit CGO_ENABLED;

      # Pass allowGoReference to hook for GOFLAGS configuration
      allowGoReference =
        if allowGoReference
        then "1"
        else "";

      # Pass tags and ldflags (used by hooks)
      inherit tags ldflags;

      goVendorDir = moduleContext + "/vendor";

      # Per-module caches of this module's dependencies, restored into
      # GOCACHE by goConfigHook before building.
      goCacheDirs = depCaches;

      # Change the working directory in prePatch so GoConfigHook sets up
      # vendor/ at the right location
      prePatch = ''
        # Create a working directory (Go ignores go.mod in /build)
        mkdir -p source
        cd source

        # Copy the synthetic go.mod from the isolated module context
        cp ${moduleContext}/go.mod ./go.mod
        touch go.sum
      '';

      configurePhase = ''
        # Set up GOCACHE directory (will compress to $out later)
        mkdir -p "$GOCACHE"

        # Mark the point in time after dependency caches were restored
        # (goConfigHook runs in postPatch, i.e. before configurePhase).
        # Only cache entries newer than this marker were created by this
        # derivation and end up in the output archive.
        touch "$TMPDIR/.cache-marker"
      '';

      buildPhase = ''
        runHook preBuild

        echo "Building ${toString (builtins.length packages)} packages from ${modulePath} to populate cache..."

        # Generate cache.go that imports all packages of this module
        printf '%s\n' ${lib.escapeShellArgs packages} | ${internal.cachegen} > cache.go

        cat cache.go

        # Build cache.go - Go will build all dependencies using its scheduler.
        # Dependency and std library artifacts are served from the restored
        # caches, so only this module's own packages are actually compiled.
        # tags/ldflags are passed with the same expansion semantics as
        # buildGoDir so cache keys match the final build.
        go build -v -mod=vendor ''${tags:+-tags=''${tags}} ''${ldflags:+-ldflags="''${ldflags}"} cache.go || true

        echo "Cache population complete"

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        echo "Compressing Go build cache (entries created by this derivation only)..."
        mkdir -p "$out"
        cd "$GOCACHE"

        find . -type f -newer "$TMPDIR/.cache-marker" -print > "$TMPDIR/new-cache-files"
        tar -cf - -T "$TMPDIR/new-cache-files" | zstd -T$NIX_BUILD_CORES -o "$out/cache.tar.zst"

        echo "Cache compressed to $out/cache.tar.zst"

        runHook postInstall
      '';
    };

  # Return a Go attribute and error out if the Go version is older than was specified in go.mod.
  selectGo = attrs: goMod:
    attrs.go or (
      if goMod == null
      then buildPackages.go
      else
        (
          let
            goVersion = goMod.go;
            goAttrs = lib.reverseList (
              builtins.filter (
                attr:
                  lib.hasPrefix "go_" attr
                  && (
                    let
                      try = builtins.tryEval buildPackages.${attr};
                    in
                      try.success && try.value ? version
                  )
                  && lib.versionAtLeast buildPackages.${attr}.version goVersion
              ) (lib.attrNames buildPackages)
            );
            goAttr = elemAt goAttrs 0;
          in (
            if goAttrs != []
            then buildPackages.${goAttr}
            else throw "go.mod specified Go version ${goVersion}, but no compatible Go attribute could be found."
          )
        )
    );

  # Strip extra data that Go adds to versions, and fall back to a version based on the date if it's a placeholder value.
  # This is data that Nix can't handle in the version attribute.
  stripVersion = version: let
    parts = elemAt (split "(\\+|-)" (removePrefix "v" version));
    v = parts 0;
    d = parts 2;
  in
    if v != "0.0.0"
    then v
    else
      "unstable-"
      + (concatStringsSep "-" [
        (substring 0 4 d)
        (substring 4 2 d)
        (substring 6 2 d)
      ]);

  mkGoEnv = {
    pwd,
    toolsGo ? pwd + "/tools.go",
    modules ? pwd + "/gomod2nix.toml",
    allowGoReference ? false,
    goModuleProxy ? null,
    ...
  } @ attrs: let
    goMod = parseGoMod (readFile "${toString pwd}/go.mod");
    modulesStruct = fromTOML (readFile modules);

    go = selectGo attrs goMod;

    vendorEnv = mkVendorEnv {
      inherit
        go
        goMod
        modulesStruct
        pwd
        goModuleProxy
        ;
    };
  in
    stdenv.mkDerivation (
      removeAttrs attrs [
        "pwd"
        "allowGoReference"
        "goModuleProxy"
      ]
      // {
        name = "${baseNameOf goMod.module}-env";

        dontUnpack = true;
        dontConfigure = true;
        dontInstall = true;

        CGO_ENABLED = attrs.CGO_ENABLED or go.CGO_ENABLED;

        # Pass allowGoReference to hook for GOFLAGS configuration
        allowGoReference =
          if allowGoReference
          then "1"
          else "";

        nativeBuildInputs = [
          rsync
          goConfigHook
        ];

        propagatedBuildInputs = [go];

        # Pass vendor directory to the setup hook
        goVendorDir = vendorEnv;

        preferLocalBuild = true;

        buildPhase =
          ''
            mkdir $out

            export GOPATH="$out"

          ''
          + optionalString (pathExists toolsGo) ''
            mkdir source
            cp ${pwd + "/go.mod"} source/go.mod
            cp ${pwd + "/go.sum"} source/go.sum
            cp ${toolsGo} source/tools.go
            cd source

            rsync -a -K --ignore-errors ${vendorEnv}/ vendor

            ${internal.install}
          '';
      }
    );

  buildGoApplication = {
    modules ? pwd + "/gomod2nix.toml",
    src ? pwd,
    pwd ? null,
    nativeBuildInputs ? [],
    allowGoReference ? false,
    meta ? {},
    passthru ? {},
    tags ? [],
    ldflags ? [],
    disableGoCache ? false,
    goModuleProxy ? null,
    ...
  } @ attrs: let
    modulesStruct =
      if modules == null
      then {}
      else fromTOML (readFile modules);

    goModPath = "${toString pwd}/go.mod";

    goMod =
      if pwd != null && pathExists goModPath
      then parseGoMod (readFile goModPath)
      else null;

    go = selectGo attrs goMod;

    defaultPackage = modulesStruct.goPackagePath or "";

    vendorEnv =
      if modulesStruct != {}
      then
        mkVendorEnv {
          inherit
            defaultPackage
            go
            goMod
            modulesStruct
            pwd
            goModuleProxy
            ;
        }
      else null;

    # Filter source to only dependency files for cache derivation
    # Use fetched source when building from goPackagePath
    # When pwd is set but doesn't contain go.mod (goMod == null), use src instead
    depFilesSrc =
      if defaultPackage != ""
      then vendorEnv.passthru.sources.${defaultPackage}
      else if goMod != null
      then pwd
      else src;

    depFilesPath =
      if (!disableGoCache && modulesStruct != {} && depFilesSrc != null)
      then
        if lib.isDerivation depFilesSrc
        then
          # Derivation sources (the fetched module in goPackagePath
          # mode, or a fetcher-produced src) are content-fixed, so
          # filtering buys no cache granularity. Worse, filtering with
          # cleanSourceWith (builtins.path) would read the directory at
          # evaluation time, forcing realisation of the derivation -
          # which breaks cross-platform evaluation when the output is
          # not substitutable (platform mismatch). Reference it
          # directly; go.mod/go.sum are copied at build time instead.
          depFilesSrc
        else
          lib.cleanSourceWith {
            src = depFilesSrc;
            filter = path: type: let
              baseName = baseNameOf path;
            in
              baseName == "go.mod" || baseName == "go.sum" || baseName == "gomod2nix.toml";
            name = "go-dep-files";
          }
      else null;

    # Per-module cache description emitted by schema version 4 generators
    cacheModulesStruct = modulesStruct.cacheModules or {};

    useModuleCache =
      !disableGoCache && modulesStruct != {} && vendorEnv != null && cacheModulesStruct != {};

    # Module-level dependency edges, restricted to modules that are cached
    depsOf = modulePath:
      builtins.filter (dep: builtins.hasAttr dep cacheModulesStruct) (
        cacheModulesStruct.${modulePath}.deps or []
      );

    # Transitive dependency closure of a module (including itself).
    # The import-derived module graph is acyclic, so this terminates.
    moduleClosure = root: let
      goMod' = m: acc:
        if builtins.hasAttr m acc
        then acc
        else builtins.foldl' (a: d: goMod' d a) (acc // {${m} = true;}) (depsOf m);
    in
      builtins.attrNames (goMod' root {});

    # Shared standard library base cache, restored by every module cache
    # derivation and the final build so std artifacts are built once per
    # toolchain instead of once per module.
    stdCache =
      if useModuleCache
      then
        mkGoStdCacheEnv {
          inherit
            go
            tags
            ldflags
            allowGoReference
            ;
          CGO_ENABLED = attrs.CGO_ENABLED or go.CGO_ENABLED;
        }
      else null;

    # One cache derivation per Go module, forming a DAG that mirrors the
    # module-level import graph. The module quotient graph is acyclic
    # (package import cycles are compile errors), so this recursive
    # attrset always terminates under Nix's lazy evaluation.
    moduleCaches =
      if useModuleCache
      then
        mapAttrs (
          modulePath: cfg:
            mkModuleCacheEnv {
              inherit
                go
                modulePath
                tags
                ldflags
                allowGoReference
                ;
              version = modulesStruct.mod.${modulePath}.version or "unknown";
              packages = cfg.packages or [];
              depCaches = [stdCache] ++ map (dep: moduleCaches.${dep}) (depsOf modulePath);
              moduleContext = mkModuleContext {
                inherit go modulePath modulesStruct;
                closure = moduleClosure modulePath;
                sources = vendorEnv.passthru.sources;
              };
              CGO_ENABLED = attrs.CGO_ENABLED or go.CGO_ENABLED;
            }
        )
        cacheModulesStruct
      else {};

    # Legacy monolithic cache path, used for gomod2nix.toml files that
    # only carry cachePackages (schema version <= 3)
    cacheEnv =
      # Check cacheModulesStruct before depFilesPath: schema >= 4
      # packages never use the legacy cache, and forcing depFilesPath
      # would instantiate the dep-files filtering for no reason.
      if (!disableGoCache && modulesStruct != {} && cacheModulesStruct == {} && depFilesPath != null)
      then
        mkGoCacheEnv {
          inherit
            go
            modulesStruct
            vendorEnv
            depFilesPath
            tags
            ldflags
            allowGoReference
            ;
          CGO_ENABLED = attrs.CGO_ENABLED or go.CGO_ENABLED;
          goMod =
            if goMod != null
            then goMod
            else {replace = {};};
        }
      else null;

    pname = attrs.pname or baseNameOf defaultPackage;
  in
    stdenv.mkDerivation (
      optionalAttrs (defaultPackage != "") {
        inherit pname;
        version = stripVersion (modulesStruct.mod.${defaultPackage}).version;
        src = vendorEnv.passthru.sources.${defaultPackage};
      }
      // optionalAttrs (hasAttr "subPackages" modulesStruct) {
        subPackages = modulesStruct.subPackages;
      }
      // attrs
      // {
        nativeBuildInputs =
          [
            go
            goConfigHook
            goBuildHook
            goCheckHook
            goInstallHook
          ]
          ++ nativeBuildInputs;

        inherit (go) GOOS GOARCH;

        CGO_ENABLED = attrs.CGO_ENABLED or go.CGO_ENABLED;

        # Pass allowGoReference to hook for GOFLAGS configuration
        allowGoReference =
          if allowGoReference
          then "1"
          else "";

        goVendorDir =
          if vendorEnv != null
          then vendorEnv
          else "";
        goCacheDir =
          if cacheEnv != null
          then cacheEnv
          else "";
        goCacheDirs =
          if useModuleCache
          then [stdCache] ++ builtins.attrValues moduleCaches
          else [];
        inherit tags ldflags;
        modRoot = attrs.modRoot or "";

        doCheck = attrs.doCheck or true;

        strictDeps = true;

        disallowedReferences = optional (!allowGoReference) go;

        passthru =
          {
            inherit go vendorEnv hooks;
            goCacheEnv = cacheEnv;
            goModuleCacheEnvs = moduleCaches;
            goStdCacheEnv = stdCache;
          }
          // optionalAttrs (hasAttr "goPackagePath" modulesStruct) {
            updateScript = let
              generatorArgs =
                if hasAttr "subPackages" modulesStruct
                then
                  concatStringsSep " " (
                    map (subPackage: modulesStruct.goPackagePath + "/" + subPackage) modulesStruct.subPackages
                  )
                else modulesStruct.goPackagePath;
            in
              writeScript "${pname}-updater" ''
                #!${runtimeShell}
                ${optionalString (pwd != null) "cd ${toString pwd}"}
                exec ${gomod2nix}/bin/gomod2nix generate ${generatorArgs}
              '';
          }
          // passthru;

        inherit meta;
      }
    );
in {
  inherit
    buildGoApplication
    mkGoEnv
    mkVendorEnv
    mkGoCacheEnv
    mkGoStdCacheEnv
    mkModuleCacheEnv
    mkModuleContext
    hooks
    ;
}
