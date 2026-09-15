# shellcheck shell=bash disable=SC2154

goCheckHook() {
  echo "Executing goCheckHook"

  runHook preCheck

  # We do not set trimpath for tests, in case they reference test assets
  export GOFLAGS=${GOFLAGS//-trimpath/}

  for pkg in $(getGoDirs test); do
    buildGoDir test "$pkg"
  done

  runHook postCheck

  echo "Finished goCheckHook"
}

if [ -z "${checkPhase-}" ]; then
  checkPhase=goCheckHook
fi
