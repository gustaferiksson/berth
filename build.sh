#!/usr/bin/env bash
# Build Berth.app into ./dist. Ad-hoc signed unless .env sets a team identity.
# Requires: Xcode, xcodegen (brew install xcodegen).
set -euo pipefail
cd "$(dirname "$0")"

if [[ -f .env ]]; then
  set -a
  source ./.env
  set +a
fi

CONFIGURATION="${CONFIGURATION:-Release}"
SIGN_ID="${CODE_SIGN_IDENTITY:--}"
SIGN_ARGS=( "CODE_SIGN_IDENTITY=${SIGN_ID}" )
if [[ "$SIGN_ID" != "-" ]]; then
  SIGN_ARGS+=( "CODE_SIGN_STYLE=Manual" "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM in .env}" "OTHER_CODE_SIGN_FLAGS=--timestamp" "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO" )
fi

MARKETING_VERSION="${MARKETING_VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)-local}"
SIGN_ARGS+=( "MARKETING_VERSION=${MARKETING_VERSION}" )

echo "▸ Generating app icon…"
./icon/generate-icons.sh

echo "▸ Generating Xcode project…"
xcodegen generate --quiet

echo "▸ Building (${CONFIGURATION})…  signing identity: ${SIGN_ID}"
xcodebuild \
  -project Berth.xcodeproj \
  -scheme Berth \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath .build \
  -quiet \
  "${SIGN_ARGS[@]}" \
  build

[[ "$CONFIGURATION" != "Release" ]] && exit 0
mkdir -p dist
rm -rf dist/Berth.app
cp -R .build/Build/Products/Release/Berth.app dist/Berth.app

echo "✅ Built dist/Berth.app"
echo "   Launch: open dist/Berth.app"
echo "   Test:   swift test --package-path Packages/BerthCore"
