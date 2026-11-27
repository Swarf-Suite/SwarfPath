#!/bin/bash
# Builds SwarfPath.app into ./build.
#
#   scripts/build-app.sh [debug|release]
#
# Release builds (scripts/release.sh sets these): SP_RELEASE=1 makes a universal app that updates from
# GitHub Releases with Sparkle, SP_VERSION=0.2 its version, SP_SPARKLE_PUBLIC_KEY the key updates are
# checked against.
#
# Signing: with a "Developer ID Application" certificate in the keychain (or SP_SIGN_IDENTITY naming
# one) the app is signed with it (hardened runtime, timestamp), as notarization needs. Without one it's
# signed ad hoc, which is fine for running your own build.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
RELEASE="${SP_RELEASE:-0}"
ARCHS=()
[[ "$RELEASE" == 1 ]] && ARCHS=(--arch arm64 --arch x86_64)
FEED_URL="${SP_FEED_URL:-https://github.com/Swarf-Suite/SwarfPath/releases/latest/download/appcast.xml}"

VERSION="${SP_VERSION:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo 0.1.0)}"
VERSION="${VERSION#v}"
# The build number is the commit time, so Sparkle always sees a later release as newer.
BUILD_NUMBER="${SP_BUILD_NUMBER:-$(git log -1 --format=%ct 2>/dev/null || echo 1)}"

IDENTITY="${SP_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ { print $2; exit }')
fi

swift build -c "$CONFIG" --product SwarfPath ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"
APP="build/SwarfPath.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/SwarfPath" "$APP/Contents/MacOS/SwarfPath"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

PLIST="$APP/Contents/Info.plist"
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
pb "Set :CFBundleShortVersionString $VERSION"
pb "Set :CFBundleVersion $BUILD_NUMBER"
if [[ "$RELEASE" == 1 ]]; then
  [[ -n "${SP_SPARKLE_PUBLIC_KEY:-}" ]] || { echo "SP_SPARKLE_PUBLIC_KEY is needed for a release build" >&2; exit 1; }
  pb "Add :SUFeedURL string $FEED_URL"
  pb "Add :SUPublicEDKey string $SP_SPARKLE_PUBLIC_KEY"
  pb "Add :SUEnableAutomaticChecks bool true"
fi

# Sparkle (linked by every build). The app isn't sandboxed, so its XPC services aren't needed.
SPARKLE="$BIN/Sparkle.framework"
[[ -d "$SPARKLE" ]] || SPARKLE=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
if ! otool -l "$APP/Contents/MacOS/SwarfPath" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/SwarfPath"
fi

# Sign inside out: Sparkle's helpers, Sparkle, then the app.
if [[ -n "$IDENTITY" ]]; then
  echo "Signing with $IDENTITY"
  SIGN=(codesign --force --sign "$IDENTITY" --options runtime --timestamp)
else
  echo "No Developer ID certificate: signing ad hoc"
  SIGN=(codesign --force --sign -)
fi
sign() { local out; out=$("${SIGN[@]}" "$1" 2>&1) || { echo "$out" >&2; return 1; }; }
FW="$APP/Contents/Frameworks/Sparkle.framework"
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign "$APP"
codesign --verify --strict --deep "$APP"
echo "Built $APP ($VERSION)"
