#!/bin/zsh
# Builds JBLControl.app into ./build. Usage: scripts/build-app.sh [--install] [--run] [--zip]
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product JBLControl
BIN="$(swift build -c release --show-bin-path)/JBLControl"

APP=build/JBLControl.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/JBLControl"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Liquid Glass icon: actool turns the Icon Composer file into Assets.car (+ AppIcon.icns for older systems).
# actool resolves relative paths against $PWD, which can be stale; pass absolute ones.
xcrun actool "$(pwd -P)/Resources/AppIcon.icon" --compile "$(pwd -P)/$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist "$(mktemp -d)/icon.plist" >/dev/null
# A real identity keeps the code requirement stable, so macOS remembers the Bluetooth
# permission across rebuilds. Falls back to ad-hoc signing when none is available.
# Release zips are signed ad-hoc: a development certificate would embed your name/email in a public download.
if [[ " $* " == *" --zip "* ]]; then
  SIGN_ID="${SIGN_ID:--}"
fi
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${SIGN_ID:--}" "$APP"
echo "Built $APP"

if [[ " $* " == *" --zip "* ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
  ditto -c -k --keepParent "$APP" "build/JBLControl-$VERSION.zip"
  echo "Zipped build/JBLControl-$VERSION.zip"
fi

if [[ " $* " == *" --install "* ]]; then
  pkill -x JBLControl || true
  rm -rf /Applications/JBLControl.app
  cp -R "$APP" /Applications/
  APP=/Applications/JBLControl.app
  echo "Installed $APP"
fi

if [[ " $* " == *" --run "* ]]; then
  pkill -x JBLControl || true
  open "$APP"
fi
