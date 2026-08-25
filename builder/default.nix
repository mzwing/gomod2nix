{
  buildPackages,
  cacert,
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
    install = mkInternalPkg "install" ./install/install.go;

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

  # A derivation whose output is $out/cache.tar.zst: a zstd-compressed
  # GOCACHE holding the compiled artifacts of `packages`, or of the Go
  # standard library when `packages` is null.
  #
  # The caches listed in depCaches are restored before building, and only
  # the entries this derivation itself created are archived. Every cache is
  # therefore disjoint, so identical artifacts are never duplicated across
  # the Nix store when several archives are restored side by side.
  mkCacheArchive = {
    name,
    go,
    # Shell snippet run in an empty source directory; must produce go.mod.
    setupModule,
    vendorDir ? "",
    packages ? null,
    depCaches ? [],
    # Build environment parameters (should match buildGoApplication)
    nativeBuildInputs ? [],
    buildInputs ? [],
    CGO_ENABLED ? go.CGO_ENABLED,
    tags ? [],
    ldflags ? [],
    allowGoReference ? false,
  }:
    stdenv.mkDerivation {
      inherit name;

      dontUnpack = true;

      nativeBuildInputs =
        [
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

      # Pass tags and ldflags (used by hooks / buildPhase)
      inherit tags ldflags;

      goVendorDir = vendorDir;
      goCacheDirs = depCaches;

      # Change the working directory in prePatch so goConfigHook sets up
      # vendor/ at the right location. Go ignores a go.mod left in /build.
      prePatch = ''
        mkdir -p source
        cd source

        ${setupModule}

        # go.sum is not consulted in -mod=vendor builds, but the go command
        # still expects the file to exist.
        touch go.sum
      '';

      configurePhase = ''
        # Set up GOCACHE directory (will compress to $out later)
        mkdir -p "$GOCACHE"

        # Mark the point in time after the dependency caches were restored
        # (goConfigHook runs in postPatch, i.e. before configurePhase).
        # Only cache entries newer than this marker were created by this
        # derivation and end up in the output archive.
        touch "$TMPDIR/.cache-marker"
      '';

      buildPhase =
        ''
          runHook preBuild

          goFlags
        ''
        + (
          if packages == null
          then ''
            echo "Building the Go standard library to populate the cache..."

            go build -v "''${goFlagsArray[@]}" std || true
          ''
          else ''
            echo "Building ${toString (builtins.length packages)} packages to populate the cache..."

            # Generate a cache.go that blank-imports every package, and let
            # the Go scheduler build them. Dependency and standard library
            # artifacts are served from the restored caches, so only this
            # module's own packages are actually compiled.
            printf '%s\n' ${lib.escapeShellArgs packages} | ${internal.cachegen} > cache.go

            cat cache.go

            go build -v "''${goFlagsArray[@]}" cache.go || true
          ''
        )
        + ''

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

  # Legacy monolithic cache for gomod2nix.toml files that carry a flat
  # cachePackages list (schema version <= 3).
  mkGoCacheEnv = {
    go,
    cachePackages,
    vendorEnv,
    depFilesPath,
    ...
  } @ args:
    mkCacheArchive (
      removeAttrs args [
        "cachePackages"
        "vendorEnv"
        "depFilesPath"
      ]
      // {
        name = "go-cache-env";
        packages = cachePackages;
        vendorDir = vendorEnv;
        setupModule = "cp ${depFilesPath}/go.mod ./go.mod";
      }
    );

  # Pre-compile the Go standard library into a GOCACHE archive.
  #
  # Since Go 1.20 the standard library is no longer distributed
  # precompiled - it is compiled into GOCACHE on first use. Without this
  # base cache, every per-module cache derivation would compile (and
  # store) its own copy of the std packages it needs, causing massive
  # duplication across the Nix store. All module cache derivations (and
  # the final build) restore this shared base cache instead.
  mkGoStdCacheEnv = {go, ...} @ args:
    mkCacheArchive (
      args
      // {
        name = "go-std-cache-${go.version}-${go.GOOS}-${go.GOARCH}";
        # The (empty) vendor directory is needed because goConfigHook sets
        # -mod=vendor in GOFLAGS.
        setupModule = ''
          printf '%s\n' ${lib.escapeShellArg ''
            module gomod2nix.invalid/std

            go ${lib.versions.majorMinor go.version}
          ''} > go.mod
          mkdir vendor
        '';
      }
    );

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

  # Build the packages of a single Go module into a GOCACHE archive, using
  # the isolated build context produced by mkModuleContext.
  mkModuleCacheEnv = {
    modulePath,
    version,
    moduleContext,
    ...
  } @ args:
    mkCacheArchive (
      removeAttrs args [
        "modulePath"
        "version"
        "moduleContext"
      ]
      // {
        # Store paths / derivation names cannot contain "/"
        name = "go-cache-${builtins.replaceStrings ["/"] ["-"] modulePath}-${stripVersion version}";
        vendorDir = moduleContext + "/vendor";
        setupModule = "cp ${moduleContext}/go.mod ./go.mod";
      }
    );

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

    useModuleCache = !disableGoCache && vendorEnv != null && cacheModulesStruct != {};

    # Module-level dependency edges, restricted to modules that are cached
    depsOf = modulePath:
      builtins.filter (dep: builtins.hasAttr dep cacheModulesStruct) (
        cacheModulesStruct.${modulePath}.deps or []
      );

    # Transitive dependency closure of a module (including itself); the walk memoises, so module-level cycles terminate.
    moduleClosure = root: let
      walk = m: acc:
        if builtins.hasAttr m acc
        then acc
        else builtins.foldl' (a: d: walk d a) (acc // {${m} = true;}) (depsOf m);
    in
      builtins.attrNames (walk root {});

    moduleClosures = mapAttrs (modulePath: _: moduleClosure modulePath) cacheModulesStruct;

    # The module quotient graph is NOT acyclic: packages in `go.opentelemetry.io/otel` import `otel/metric` while packages in `otel/metric` import `otel`, which is legal because no *package* import cycle exists.
    # Since an edge m -> d always puts d in m's closure, `m` being in d's closure means the two share a cycle, so this keeps exactly the edges that cross between strongly connected components and the cache derivations form a DAG.
    # Modules inside a cycle then compile each other's packages into their own archive instead of restoring them.
    cacheDepsOf = modulePath:
      builtins.filter (dep: !(builtins.elem modulePath moduleClosures.${dep})) (depsOf modulePath);

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

    # One cache derivation per Go module, wired along the acyclic edge subset so this recursive attrset terminates under Nix's lazy evaluation.
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
              depCaches = [stdCache] ++ map (dep: moduleCaches.${dep}) (cacheDepsOf modulePath);
              moduleContext = mkModuleContext {
                inherit go modulePath modulesStruct;
                closure = moduleClosures.${modulePath};
                sources = vendorEnv.passthru.sources;
              };
              CGO_ENABLED = attrs.CGO_ENABLED or go.CGO_ENABLED;
            }
        )
        cacheModulesStruct
      else {};

    # Legacy monolithic cache path, used for gomod2nix.toml files that
    # only carry cachePackages (schema version <= 3). Schema >= 4 packages
    # describe their cache in cacheModules instead, and a toml carrying
    # neither has nothing to pre-compile - in both cases building the
    # derivation (and forcing depFilesPath) would be pure overhead.
    cachePackages = modulesStruct.cachePackages or [];

    cacheEnv =
      if (!disableGoCache && cacheModulesStruct == {} && cachePackages != [] && depFilesPath != null)
      then
        mkGoCacheEnv {
          inherit
            go
            cachePackages
            vendorEnv
            depFilesPath
            tags
            ldflags
            allowGoReference
            ;
          CGO_ENABLED = attrs.CGO_ENABLED or go.CGO_ENABLED;
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
        goCacheDirs =
          if useModuleCache
          then [stdCache] ++ builtins.attrValues moduleCaches
          else optional (cacheEnv != null) cacheEnv;
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
    hooks
    ;
}
