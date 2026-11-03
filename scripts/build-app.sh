#!/bin/bash
# Builds dist/Askme.app.
#   CONFIGURATION     release (default) or debug
#   ARCHS             e.g. "arm64 x86_64" for a universal binary; default is this Mac's architecture
#   VERSION           overrides CFBundleShortVersionString in the bundle (release builds use the tag)
#   BUILD_NUMBER      overrides CFBundleVersion in the bundle
#   SIGNING_IDENTITY  Developer ID identity; default is an ad-hoc signature
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-release}"
IDENTITY="${SIGNING_IDENTITY:--}"
APP="$PWD/dist/Askme.app"

BUILD_FLAGS=(-c "$CONFIGURATION")
for arch in ${ARCHS:-}; do
    BUILD_FLAGS+=(--arch "$arch")
done

swift build "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Askme" "$APP/Contents/MacOS/Askme"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

# Use the same vector master for Finder / app icons and the menu bar.
ICON_BUILD="$PWD/.build/branding"
mkdir -p "$ICON_BUILD"
xcrun swiftc Sources/Askme/BrandIcon.swift scripts/generate-icons.swift -o "$ICON_BUILD/generate-icons"
"$ICON_BUILD/generate-icons" "$ICON_BUILD/Askme.iconset"
xcrun iconutil -c icns "$ICON_BUILD/Askme.iconset" -o "$APP/Contents/Resources/Askme.icns"

SIGN_OPTIONS=(--force --sign "$IDENTITY" --entitlements Resources/Askme.entitlements)
if [[ "$IDENTITY" != "-" ]]; then
    SIGN_OPTIONS+=(--options runtime --timestamp)
fi
codesign "${SIGN_OPTIONS[@]}" "$APP"
codesign --verify --strict "$APP"
printf '\nBuilt: %s (%s)\nRun: open "%s"\n' "$APP" "$(lipo -archs "$APP/Contents/MacOS/Askme")" "$APP"
