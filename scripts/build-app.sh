#!/bin/zsh
# Builds JBLControl.app into ./build. Usage: scripts/build-app.sh [--install] [--run] [--zip] [--dmg]
set -euo pipefail
cd "${0:A:h}/.."

# Universal binary: Apple Silicon and Intel.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --product JBLControl "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/JBLControl"

APP=build/JBLControl.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/JBLControl"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Liquid Glass icon + sunset accent color: actool compiles both into Assets.car (+ AppIcon.icns).
# actool resolves relative paths against $PWD, which can be stale; pass absolute ones.
xcrun actool "$(pwd -P)/Resources/Assets.xcassets" "$(pwd -P)/Resources/AppIcon.icon" \
  --compile "$(pwd -P)/$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 14.0 --app-icon AppIcon --accent-color AccentColor \
  --output-partial-info-plist "$(mktemp -d)/icon.plist" >/dev/null
# A real identity keeps the code requirement stable, so macOS remembers the Bluetooth
# permission across rebuilds. Falls back to ad-hoc signing when none is available.
# Release zips are signed ad-hoc: a development certificate would embed your name/email in a public download.
if [[ " $* " == *" --zip "* || " $* " == *" --dmg "* ]]; then
  SIGN_ID="${SIGN_ID:--}"
fi
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${SIGN_ID:--}" "$APP"
echo "Built $APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

if [[ " $* " == *" --zip "* ]]; then
  ditto -c -k --keepParent "$APP" "build/JBLControl-$VERSION.zip"
  echo "Zipped build/JBLControl-$VERSION.zip"
  shasum -a 256 "build/JBLControl-$VERSION.zip"
fi

# Drag-to-Applications installer. Needs dmgbuild:
#   python3 -m venv build/.venv && build/.venv/bin/pip install dmgbuild
if [[ " $* " == *" --dmg "* ]]; then
  [[ -x build/.venv/bin/dmgbuild ]] || { echo "dmgbuild missing; see comment in build-app.sh"; exit 1; }
  [[ -f Resources/DMG/background.tiff ]] || {
    swift scripts/make-dmg-background.swift
    tiffutil -cathidpicheck Resources/DMG/background.png Resources/DMG/background@2x.png -out Resources/DMG/background.tiff
  }
  rm -f "build/JBLControl-$VERSION.dmg"
  build/.venv/bin/dmgbuild -s scripts/dmg-settings.py -D app="$APP" -D background=Resources/DMG/background.tiff \
    "JBLControl" "build/JBLControl-$VERSION.dmg" >/dev/null
  echo "Built build/JBLControl-$VERSION.dmg"
  shasum -a 256 "build/JBLControl-$VERSION.dmg"
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
