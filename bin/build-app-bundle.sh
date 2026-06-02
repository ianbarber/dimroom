#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/App"
BUILD_DIR="$APP_DIR/.build/debug"
BUNDLE_DIR="$BUILD_DIR/Dimroom.app"
CONTENTS="$BUNDLE_DIR/Contents"

echo "Building Dimroom..."
swift build --package-path "$APP_DIR"

echo "Assembling app bundle..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BUILD_DIR/Dimroom" "$CONTENTS/MacOS/Dimroom"

if [ -f "$APP_DIR/Resources/AppIcon.icns" ]; then
    cp "$APP_DIR/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
else
    echo "Warning: AppIcon.icns not found — run bin/build-icon.sh first"
fi

cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.ianbarber.dimroom</string>
    <key>CFBundleName</key>
    <string>Dimroom</string>
    <key>CFBundleExecutable</key>
    <string>Dimroom</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

# Re-sign with an explicit, stable identifier. Without this the Swift toolchain's
# inherited ad-hoc signature uses a content-hash-derived identifier that changes on
# every rebuild, so macOS treats each build as a different app and the Keychain's
# "Always Allow Dimroom" ACL never matches across builds. An explicit ad-hoc
# identifier keeps the designated requirement stable so the ACL keeps matching.
echo "Signing app bundle..."
codesign --force --sign - --identifier com.ianbarber.dimroom "$BUNDLE_DIR"
codesign -dvv "$BUNDLE_DIR" 2>&1 | grep -E '^(Identifier|Signature)=' || true

echo "Done. App bundle at:"
echo "  $BUNDLE_DIR"
echo ""
echo "Launch with:"
echo "  open $BUNDLE_DIR"
