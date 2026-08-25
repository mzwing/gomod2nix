# shellcheck shell=bash disable=SC2154

# Assemble the tag/ldflag arguments into goFlagsArray. Every `go` invocation
# in every derivation must use these, otherwise the cache-priming builds and
# the final build compute different cache keys and the caches are ignored.
#
# `tags` arrives space-separated from the Nix list, but `go` wants one
# comma-separated argument; leaving the spaces in would split the rest of the
# tags into import paths.
goFlags() {
    goFlagsArray=()
    if [ -n "${tags:-}" ]; then
        goFlagsArray+=("-tags=${tags// /,}")
    fi
    if [ -n "${ldflags:-}" ]; then
        goFlagsArray+=("-ldflags=$ldflags")
    fi
}

# Shared functions used by build and check hooks
buildGoDir() {
    local cmd="$1" dir="$2"

    # goBuildHook is the only writer of this file, so it is absent whenever the package brings its own buildPhase.
    if [ -f "$TMPDIR/buildFlagsArray" ]; then
        . "$TMPDIR/buildFlagsArray"
    fi

    goFlags

    declare -a flags
    # `set -u` makes expanding a never-declared buildFlagsArray fatal.
    flags+=($buildFlags ${buildFlagsArray[@]+"${buildFlagsArray[@]}"})
    flags+=("${goFlagsArray[@]}")
    flags+=("-v" "-p" "$NIX_BUILD_CORES")

    if [ "$cmd" = "test" ]; then
        flags+=(-vet=off)
        flags+=($checkFlags)
    fi

    local OUT
    if ! OUT="$(go "$cmd" "${flags[@]}" "$dir" 2>&1)"; then
        if echo "$OUT" | grep -qE 'imports .*?: no Go files in'; then
            echo "$OUT" >&2
            return 1
        fi
        if ! echo "$OUT" | grep -qE '(no( buildable| non-test)?|build constraints exclude all) Go (source )?files'; then
            echo "$OUT" >&2
            return 1
        fi
    fi
    if [ -n "$OUT" ]; then
        echo "$OUT" >&2
    fi
    return 0
}

getGoDirs() {
    local type
    type="$1"
    if [ -n "$subPackages" ]; then
        echo "$subPackages" | sed "s,\(^\| \),\1./,g"
    else
        find . -type f -name \*"$type".go -exec dirname {} \; | grep -v "/vendor/" | sort --unique | grep -v "$exclude"
    fi
}

goConfigHook() {
    echo "Executing goConfigHook"

    export GOCACHE=$TMPDIR/go-cache
    export GOPATH="$TMPDIR/go"
    export GOSUMDB=off
    export GOPROXY=off
    export GO_NO_VENDOR_CHECKS=1
    export GO111MODULE=on

    export GOFLAGS="${GOFLAGS:+$GOFLAGS } -mod=vendor"
    if [ "${allowGoReference:-}" != "1" ]; then
        export GOFLAGS="$GOFLAGS -trimpath"
    fi

    cd "${modRoot:-.}"

    # Set up vendor directory if goVendorDir is provided
    if [ -n "${goVendorDir-}" ]; then
        echo "Setting up vendor directory from ${goVendorDir}"
        rm -rf vendor
        @rsync@ -a -K --ignore-errors "${goVendorDir}"/ vendor
    fi

    # Restore the build caches listed in goCacheDirs. Each entry is a cache
    # derivation containing cache.tar.zst. GOCACHE is a content-addressed file
    # store, so extracting multiple archives into it is a safe union
    # operation: colliding paths have identical contents and extraction order
    # does not matter.
    if [ -n "${goCacheDirs-}" ]; then
        for cacheDir in ${goCacheDirs}; do
            echo "Restoring Go build cache from $cacheDir/cache.tar.zst"
            mkdir -p "$GOCACHE"
            @zstd@ -d -c "$cacheDir/cache.tar.zst" | @tar@ -xf - -C "$GOCACHE"
        done
        chmod -R +w "$GOCACHE"
    fi

    # Set up exclude pattern for getGoDirs
    exclude='\(/_\|examples\|Godeps\|testdata'
    if [[ -n "$excludedPackages" ]]; then
      IFS=' ' read -r -a excludedArr <<<"$excludedPackages"
      printf -v excludedAlternates '%s\\|' "${excludedArr[@]}"
      excludedAlternates=${excludedAlternates%\\|} # drop final \| added by printf
      exclude+='\|'"$excludedAlternates"
    fi
    exclude+='\)'
    export exclude

    echo "Finished goConfigHook"
}

postPatchHooks+=(goConfigHook)
