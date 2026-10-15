#!/bin/zsh
# Builds build/PhotoCrop.app.
#   ./build.sh            build
#   ./build.sh --install  build and copy to /Applications
#   ./build.sh --test     build and run the self-test (Tests/main.swift)
set -euo pipefail
cd "${0:A:h}"

if ! command -v swiftc >/dev/null; then
  echo "Swift isn't installed. Run:  xcode-select --install   then run this script again." >&2
  exit 1
fi
if ! command -v jpegtran >/dev/null && [[ ! -x /opt/homebrew/bin/jpegtran && ! -x /usr/local/bin/jpegtran ]]; then
  echo "Note: lossless (Original quality) crops need jpegtran:  brew install jpeg-turbo" >&2
fi

FLAGS=(-O -swift-version 5 -target "$(uname -m)-apple-macos15")
APP=build/PhotoCrop.app

if [[ "${1:-}" == "--test" ]]; then
  mkdir -p build
  swiftc "${FLAGS[@]}" -o build/selftest ${(f)"$(ls Sources/*.swift | grep -v '/main.swift$')"} Tests/main.swift
  shift
  exec build/selftest "$@"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc "${FLAGS[@]}" -o "$APP/Contents/MacOS/PhotoCrop" Sources/*.swift
cp Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/PhotoCrop.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/PhotoCrop.app"
fi
