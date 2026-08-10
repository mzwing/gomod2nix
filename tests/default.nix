# Offline, fully sandboxed end-to-end tests.
#
# Every test here runs inside the Nix sandbox without network access:
#
#   - Module downloads go through a static local module proxy
#     (GOPROXY=file://...) generated from the synthetic fixture modules in
#     fixtures/modules by tests/proxygen.go.
#   - The generator tests run the gomod2nix binary against that proxy and
#     diff its output against the committed golden gomod2nix.toml files.
#   - The builder tests pass goModuleProxy to buildGoApplication/mkGoEnv so
#     the fixed-output module fetchers pull from the same local proxy.
#
# To regenerate a golden file after intentionally changing generator
# behavior, build the proxy locally and run gomod2nix against it, e.g.:
#
#   go build -o /tmp/proxygen ./tests/proxygen.go
#   /tmp/proxygen -out /tmp/proxy example.com/depa@v1.0.0=tests/fixtures/modules/depa ...
#   cd tests/cases/basic
#   GOPROXY=file:///tmp/proxy GOSUMDB=off gomod2nix --dir . --outdir .
#   git add gomod2nix.toml
{
  lib,
  runCommand,
  go,
  gomod2nix,
  buildGoApplication,
  mkGoEnv,
}: let
  # Single-file, stdlib-only helper that assembles the module proxy.
  proxygen =
    runCommand "gomod2nix-test-proxygen"
    {
      nativeBuildInputs = [go];
    } ''
      export HOME=$(mktemp -d)
      go build -o "$HOME/bin" ${./proxygen.go}
      mv "$HOME/bin" "$out"
    '';

  # Static Go module proxy (proxy protocol layout) holding the synthetic
  # fixture modules.
  # Static Go module proxy (proxy protocol layout) holding the synthetic
  # fixture modules. proxygen's output IS the binary (a single store
  # file), so it is referenced by path instead of via nativeBuildInputs.
  proxy =
    runCommand "gomod2nix-test-proxy"
    {
      preferLocalBuild = true;
    } ''
      ${proxygen} -out $out \
        example.com/depa@v1.0.0=${./fixtures/modules/depa} \
        example.com/depa-fork@v1.0.1=${./fixtures/modules/depa-fork} \
        example.com/depb@v1.0.0=${./fixtures/modules/depb} \
        example.com/tool@v1.0.0=${./fixtures/modules/tool}
    '';

  proxyUrl = "file://${proxy}";

  # Offline Go environment for running the generator inside a check.
  offlineGoEnv = ''
    export GOPROXY=${proxyUrl}
    export GOSUMDB=off
    export GOTOOLCHAIN=local
    export GOFLAGS=-mod=mod
    export HOME=$TMPDIR/home
    export GOPATH=$TMPDIR/gopath
    export GOMODCACHE=$TMPDIR/gomodcache
    export GOCACHE=$TMPDIR/gocache
    mkdir -p "$HOME"
  '';

  # Run gomod2nix on a test case (copied to a writable temp dir, golden
  # file removed first so no hashes are reused from the cache) and diff
  # the output against the committed golden file.
  generateCheck = {
    name,
    case,
    extraArgs ? "",
  }:
    runCommand "test-${name}"
    {
      nativeBuildInputs = [gomod2nix go];
    } ''
      ${offlineGoEnv}

      cp -r ${case} case
      chmod -R u+w case
      cd case
      rm -f gomod2nix.toml

      gomod2nix --dir . --outdir . ${extraArgs}

      diff -u ${case}/gomod2nix.toml gomod2nix.toml
      touch $out
    '';

  # Run a built binary and assert on its output.
  assertOutput = {
    name,
    drv,
    bin,
    expected,
  }:
    runCommand "test-${name}" {} ''
      output=$(${drv}/bin/${bin})
      if [ "$output" != "${expected}" ]; then
        echo "FAIL: expected '${expected}', got '$output'"
        exit 1
      fi
      touch $out
    '';

  basicBuild = buildGoApplication {
    pname = "testmain";
    version = "0.0.1";
    src = ./cases/basic;
    modules = ./cases/basic/gomod2nix.toml;
    goModuleProxy = proxyUrl;
  };

  mkgoenvEnv = mkGoEnv {
    pwd = ./cases/mkgoenv;
    goModuleProxy = proxyUrl;
  };

  # The module cache derivations must not depend on the application
  # sources: a source-only change rebuilds only the final derivation.
  # Compare drvPaths (instantiation-time, no builds needed) between the
  # original sources and a copy with a comment appended to main.go.
  moduleCacheSrcChanged = runCommand "module-cache-src-changed" {} ''
    cp -r ${./cases/module-cache} $out
    chmod -R u+w $out
    echo '// source-only change' >> $out/main.go
  '';

  mkModuleCacheBuild = src:
    buildGoApplication {
      pname = "testcache";
      version = "0.0.1";
      inherit src;
      modules = ./cases/module-cache/gomod2nix.toml;
      goModuleProxy = proxyUrl;
    };

  moduleCacheA = mkModuleCacheBuild ./cases/module-cache;
  moduleCacheB = mkModuleCacheBuild moduleCacheSrcChanged;

  cacheDrvPaths = build:
    lib.sort lessThan (
      map (drv: drv.drvPath) (lib.attrValues build.goModuleCacheEnvs)
      ++ [build.goStdCacheEnv.drvPath]
    );

  lessThan = a: b: a < b;

  # Probe derivation that can never be built. If the builder filtered a
  # derivation source with builtins.path (cleanSourceWith) at evaluation
  # time, Nix would try to realise this source while instantiating the
  # package and evaluation would fail. After the fix, the source is only
  # referenced (instantiation), never realised at evaluation time.
  brokenSrc = runCommand "broken-src" {} ''false'';

  # Legacy (schema <= 3, cachePackages) package whose src is a
  # derivation: depFilesSrc falls back to src, which must be referenced
  # directly instead of being filtered at evaluation time.
  legacyForeignSrcPkg = buildGoApplication {
    pname = "legacy-foreign-src";
    version = "0.0.1";
    src = brokenSrc;
    modules = ./cases/legacy-cache/gomod2nix.toml;
    goModuleProxy = proxyUrl;
  };

  # Legacy (schema <= 3) package in goPackagePath mode: the package
  # source is the fetched module itself, a fixed-output derivation whose
  # hash is deliberately wrong so the fetch can never succeed.
  # Instantiating the package must still work: the module source may
  # only be realised at build time, never during evaluation.
  legacyGoPkgPathPkg = buildGoApplication {
    modules = ./cases/legacy-gopkgpath/gomod2nix.toml;
    goModuleProxy = proxyUrl;
  };
in {
  # Generator: basic project against the offline proxy.
  test-generate-basic = generateCheck {
    name = "generate-basic";
    case = ./cases/basic;
  };

  # Generator: remote replace (golden carries `replaced`) and local path
  # replace (excluded from cacheModules) with --with-deps.
  test-generate-replace = generateCheck {
    name = "generate-replace";
    case = ./cases/replace;
    extraArgs = "--with-deps";
  };

  # Generator: `gomod2nix generate pkg@version` temp-project path.
  test-generate-cli-args =
    runCommand "test-generate-cli-args"
    {
      nativeBuildInputs = [gomod2nix go];
    } ''
      ${offlineGoEnv}

      mkdir work
      cd work
      gomod2nix generate example.com/tool/cmd/tool@v1.0.0

      diff -u ${./cases/cli-args/gomod2nix.toml} gomod2nix.toml
      touch $out
    '';

  # Builder: buildGoApplication from a golden toml, run the binary.
  test-build-basic = assertOutput {
    name = "build-basic";
    drv = basicBuild;
    bin = "testmain";
    expected = "hello from depa via depb";
  };

  # Builder: mkGoEnv installs tools.go tools offline.
  test-build-mkgoenv = assertOutput {
    name = "build-mkgoenv";
    drv = mkgoenvEnv;
    bin = "tool";
    expected = "tool says hi";
  };

  # Builder: per-module cache DAG builds, and cache derivations are
  # source-independent (eval-time drvPath assertions).
  test-build-module-cache = assert (lib.assertMsg
    (cacheDrvPaths moduleCacheA == cacheDrvPaths moduleCacheB)
    "a source-only change would rebuild module cache derivations");
  assert (lib.assertMsg
    (moduleCacheA.drvPath != moduleCacheB.drvPath)
    "a source-only change did not rebuild the final derivation");
    assertOutput {
      name = "build-module-cache";
      drv = moduleCacheB;
      bin = "testcache";
      expected = "hello from depa via depb";
    };

  # Eval-only regression test: instantiating a legacy-cache package with
  # a derivation src must not realise the source at evaluation time.
  # Referencing .drvPath forces instantiation; brokenSrc can never be
  # built, so any evaluation-time filtering would fail right here.
  test-eval-legacy-foreign-src = assert (lib.assertMsg
    (legacyForeignSrcPkg.drvPath != "")
    "legacy-cache package with derivation src failed to instantiate");
    runCommand "test-eval-legacy-foreign-src" {} ''
      touch $out
    '';

  # Eval-only regression test: instantiating a goPackagePath-mode
  # package must not realise the module fetch (fixed-output derivation)
  # at evaluation time - the wrong hash makes any such attempt fail.
  test-eval-legacy-gopkgpath-foreign-src = assert (lib.assertMsg
    (legacyGoPkgPathPkg.drvPath != "")
    "goPackagePath-mode package failed to instantiate");
    runCommand "test-eval-legacy-gopkgpath-foreign-src" {} ''
      touch $out
    '';
}
