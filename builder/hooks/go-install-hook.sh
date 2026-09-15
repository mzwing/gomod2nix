# shellcheck shell=bash disable=SC2154

goInstallHook() {
  echo "Executing goInstallHook"

  runHook preInstall

  mkdir -p "$out"
  dir="$GOPATH/bin"
  [ -e "$dir" ] && cp -r "$dir" "$out"

  runHook postInstall

  echo "Finished goInstallHook"
}

if [ -z "${installPhase-}" ]; then
  installPhase=goInstallHook
fi
