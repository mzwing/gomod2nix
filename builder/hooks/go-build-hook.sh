# shellcheck shell=bash disable=SC2154

goBuildHook() {
  echo "Executing goBuildHook"

  runHook preBuild

  if (("${NIX_DEBUG:-0}" >= 1)); then
    buildFlagsArray+=(-x)
  fi

  if [ ${#buildFlagsArray[@]} -ne 0 ]; then
    declare -p buildFlagsArray >"$TMPDIR/buildFlagsArray"
  else
    touch "$TMPDIR/buildFlagsArray"
  fi

  if [ -z "$enableParallelBuilding" ]; then
    export NIX_BUILD_CORES=1
  fi

  for pkg in $(getGoDirs ""); do
    echo "Building subPackage $pkg"
    buildGoDir install "$pkg"
  done

  # Normalize cross-compiled builds w.r.t. native builds
  # shellcheck disable=SC2050  # Nix substitutes both placeholders at build time.
  if [ "@hostPlatformConfig@" != "@buildPlatformConfig@" ]; then
    (
      dir=$GOPATH/bin/${GOOS}_${GOARCH}
      if [[ -n "$(
        shopt -s nullglob
        echo "$dir"/*
      )" ]]; then
        mv "$dir"/* "$dir"/..
      fi
      if [[ -d $dir ]]; then
        rmdir "$dir"
      fi
    )
  fi

  runHook postBuild

  echo "Finished goBuildHook"
}

if [ -z "${buildPhase-}" ]; then
  buildPhase=goBuildHook
fi
