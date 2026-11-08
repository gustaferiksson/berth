#!/usr/bin/env bash
# Copy Monaco's prebuilt min/vs into Resources/Review/vs. Skips when already present.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.52.2"
TARGET="Resources/Review/vs"
[[ -f "$TARGET/loader.js" && -f "$TARGET/editor/editor.main.js" ]] && exit 0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "▸ Fetching monaco-editor ${VERSION}…"
curl -fsSL "https://registry.npmjs.org/monaco-editor/-/monaco-editor-${VERSION}.tgz" -o "$WORK/monaco.tgz"
mkdir "$WORK/x"
tar -xzf "$WORK/monaco.tgz" -C "$WORK/x" package/min/vs
[[ -f "$WORK/x/package/min/vs/loader.js" && -f "$WORK/x/package/min/vs/editor/editor.main.js" ]] || { echo "monaco-editor tarball lacks min/vs" >&2; exit 1; }

rm -rf "$TARGET"
cp -R "$WORK/x/package/min/vs" "$TARGET"
