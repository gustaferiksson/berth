#!/usr/bin/env bash
# Exports the Ad Hoc dist/BerthRemote.ipa and dist/manifest.plist. The Apple Distribution identity must already be in a keychain.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)-local}"
BUILD="${BUILD:-1}"
PROFILE="${IOS_ADHOC_PROFILE_PATH:-.secrets/Berth_Remote_Ad_Hoc.mobileprovision}"
PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

[[ -f "$PROFILE" ]] || { echo "✗ $PROFILE not found"; exit 1; }
mkdir -p "$PROFILES_DIR"
cp "$PROFILE" "$PROFILES_DIR/$(security cms -D -i "$PROFILE" | plutil -extract UUID raw -o - -).mobileprovision"

echo "▸ Generating Xcode project…"
xcodegen generate --quiet

echo "▸ Archiving Berth Remote ${VERSION} (${BUILD})…"
rm -rf .build/BerthRemote.xcarchive .build/export
xcodebuild -project Berth.xcodeproj -scheme BerthRemote -configuration Release -derivedDataPath .build -quiet \
  -destination 'generic/platform=iOS' -archivePath .build/BerthRemote.xcarchive \
  "MARKETING_VERSION=${VERSION}" "CURRENT_PROJECT_VERSION=${BUILD}" archive

echo "▸ Exporting the Ad Hoc IPA…"
xcodebuild -exportArchive -quiet -archivePath .build/BerthRemote.xcarchive -exportPath .build/export \
  -exportOptionsPlist Signing/ExportOptions-AdHoc.plist
mkdir -p dist
cp .build/export/BerthRemote.ipa .build/export/manifest.plist dist/
echo "✅ Built dist/BerthRemote.ipa and dist/manifest.plist"
