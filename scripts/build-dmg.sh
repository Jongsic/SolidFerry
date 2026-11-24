#!/usr/bin/env bash
# Builds SolidFerry.app (Release, ad-hoc signed, not notarized) and packages it into a DMG
# under build/. The release workflow runs this same script, so a local run produces exactly
# what a GitHub release ships.
#
# Usage: scripts/build-dmg.sh [version]
#   version   e.g. v0.2.0 — sets the app's version and names the DMG
#             (default: `git describe`, e.g. v1.3.0 or abc1234-dirty)
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
# The app's version: a tag's number (v1.2.3 → 1.2.3); anything else keeps project.yml's.
MARKETING=()
[[ "$VERSION" =~ ^v([0-9]+(\.[0-9]+)*)$ ]] && MARKETING=("MARKETING_VERSION=${BASH_REMATCH[1]}")

command -v xcodegen >/dev/null 2>&1 || { echo "error: xcodegen not found — brew install xcodegen" >&2; exit 1; }

# Built in Xcode's default DerivedData, which Spotlight doesn't index, so the built app
# doesn't show up next to an installed one. build/ ends up holding only the DMG.
xcodegen generate --quiet
xcodebuild -project SolidFerry.xcodeproj -scheme SolidFerry -configuration Release -destination 'generic/platform=macOS' \
    CODE_SIGN_IDENTITY=- ${MARKETING[@]+"${MARKETING[@]}"} -quiet build

PRODUCTS=$(xcodebuild -project SolidFerry.xcodeproj -scheme SolidFerry -configuration Release -destination 'generic/platform=macOS' \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')
STAGING="build/dmg-staging"
DMG="build/SolidFerry-${VERSION}.dmg"

rm -rf "$STAGING" && mkdir -p "$STAGING"
cp -R "$PRODUCTS/SolidFerry.app" "$STAGING/"
cp LICENSE "$STAGING/LICENSE.txt"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "SolidFerry" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "→ $DMG"
