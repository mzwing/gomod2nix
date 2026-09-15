# shellcheck shell=bash disable=SC2154
# shellcheck source=/dev/null
source "$stdenv/setup"

HOME="$(mktemp -d)"
export HOME

# Optional explicit module proxy override (e.g. a file:// proxy for
# offline builds). A dedicated variable is used because the daemon may
# clobber GOPROXY via impureEnvVars.
if [ -n "${goModuleProxy:-}" ]; then
  export GOPROXY="$goModuleProxy"
  export GOSUMDB=off
fi

# Call once first outside of subshell for better error reporting
go mod download "$goPackagePath@$version"

dir=$(go mod download --json "$goPackagePath@$version" | jq -r .Dir)

chmod -R +w "$dir"
find "$dir" -iname '.ds_store' -exec rm -rf {} +

cp -r "$dir" "$out"
