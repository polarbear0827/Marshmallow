#!/bin/bash
# Builds Marshmallow.app (universal) into ./build and a zip into ./dist.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(cat VERSION)}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/app.noindex/Marshmallow.app"

echo "▸ Building Marshmallow $VERSION ($BUILD_NUMBER)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Marshmallow"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"  # app.noindex: keep dev builds out of Spotlight
cp "$BIN" "$APP/Contents/MacOS/Marshmallow"

# The icon is committed (Resources/AppIcon.icns) so CI builds are reproducible.
# To redraw it: swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Marshmallow</string>
  <key>CFBundleDisplayName</key><string>Marshmallow</string>
  <key>CFBundleIdentifier</key><string>io.github.polarbear0827.marshmallow</string>
  <key>CFBundleExecutable</key><string>Marshmallow</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Marshmallow 透過 Pages、Numbers、Keynote 轉換 Word、Excel、PowerPoint 檔案。</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 polarbear0827. MIT License.</string>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)"
cat > build/entitlements.plist <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.automation.apple-events</key><true/>
</dict></plist>
ENT
codesign --force --deep --options runtime --entitlements build/entitlements.plist --sign - "$APP"

mkdir -p dist
ZIP="dist/Marshmallow-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "✓ $APP"
echo "✓ $ZIP"
