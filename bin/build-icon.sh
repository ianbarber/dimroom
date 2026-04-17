#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR_ICONSET="$(mktemp -d)/AppIcon.iconset"
APP_RESOURCES="$REPO_ROOT/App/Resources"
SPM_RESOURCES="$REPO_ROOT/App/Sources/Resources"

mkdir -p "$TMPDIR_ICONSET" "$APP_RESOURCES" "$SPM_RESOURCES"

echo "Rendering icon set..."
swift run --package-path "$REPO_ROOT/Packages/AppIcon" dimroom-icongen --output "$TMPDIR_ICONSET"

echo "Converting to .icns via iconutil..."
iconutil -c icns "$TMPDIR_ICONSET" -o "$SPM_RESOURCES/AppIcon.icns"

cp "$SPM_RESOURCES/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
cp "$TMPDIR_ICONSET/icon_1024.png" "$APP_RESOURCES/icon_1024.png"

rm -rf "$(dirname "$TMPDIR_ICONSET")"

echo "Done."
echo "  $SPM_RESOURCES/AppIcon.icns  (SPM Bundle.module)"
echo "  $APP_RESOURCES/AppIcon.icns  (build-app-bundle.sh)"
echo "  $APP_RESOURCES/icon_1024.png (source master)"
