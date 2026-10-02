#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="此刻.app"
APP_DIR="$PROJECT_DIR/dist/$APP_NAME"

cd "$PROJECT_DIR"
swift build -c release
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$PROJECT_DIR/.build/release/Cike" "$APP_DIR/Contents/MacOS/Cike"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>Cike</string>
    <key>CFBundleIdentifier</key><string>com.cike.menubar</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>此刻</string>
    <key>CFBundleDisplayName</key><string>此刻</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>MeituanRecommendationEndpoint</key><string></string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
/usr/bin/codesign --force --deep --sign - --identifier com.cike.menubar "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
echo "Built: $APP_DIR"
