#!/bin/bash
# Build TokenTracker.app (native SwiftUI) and a DMG installer — no Xcode required.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="Token Tracker"
BIN_NAME="TokenTracker"
BUNDLE_ID="nl.dockerized.tokentracker"
VERSION="1.0.0"
DEPLOY_TARGET="14.0"

BUILD="$ROOT/build"
APP="$BUILD/$BIN_NAME.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
DMG="$ROOT/TokenTracker-Installer.dmg"

SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"   # arm64 or x86_64

echo "==> Cleaning"
rm -rf "$APP" "$DMG"
mkdir -p "$MACOS" "$RES"

echo "==> Compiling ($ARCH, macOS $DEPLOY_TARGET)"
swiftc -parse-as-library -O \
    -target "${ARCH}-apple-macos${DEPLOY_TARGET}" \
    -sdk "$SDK" \
    $(ls "$ROOT"/Sources/*.swift) \
    -o "$MACOS/$BIN_NAME"

echo "==> Generating app icon"
ICON_OK=0
if swiftc -O -sdk "$SDK" "$ROOT/Tools/makeicon.swift" -o "$BUILD/makeicon" 2>/dev/null; then
    if "$BUILD/makeicon" "$BUILD/icon_1024.png" >/dev/null 2>&1; then
        ICONSET="$BUILD/AppIcon.iconset"
        rm -rf "$ICONSET"; mkdir -p "$ICONSET"
        for sz in 16 32 64 128 256 512 1024; do
            sips -z $sz $sz "$BUILD/icon_1024.png" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null 2>&1 || true
        done
        # @2x variants
        cp "$ICONSET/icon_32x32.png"   "$ICONSET/icon_16x16@2x.png"   2>/dev/null || true
        cp "$ICONSET/icon_64x64.png"   "$ICONSET/icon_32x32@2x.png"   2>/dev/null || true
        cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png" 2>/dev/null || true
        cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png" 2>/dev/null || true
        cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png" 2>/dev/null || true
        if iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns" 2>/dev/null; then
            ICON_OK=1
        fi
    fi
fi
[ "$ICON_OK" = "1" ] && echo "    icon: ok" || echo "    icon: skipped (default will be used)"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$BIN_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>$DEPLOY_TARGET</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key><string>Local usage dashboard for Claude &amp; DeepSeek.</string>
$( [ "$ICON_OK" = "1" ] && echo "    <key>CFBundleIconFile</key><string>AppIcon</string>" )
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "    (codesign skipped)"

echo "==> Building DMG installer"
STAGING="$BUILD/dmg-staging"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo ""
echo "==> Done."
echo "    App:       $APP"
echo "    Installer: $DMG"
echo ""
echo "Install by opening the DMG and dragging Token Tracker to Applications,"
echo "or run: ./install.sh"
