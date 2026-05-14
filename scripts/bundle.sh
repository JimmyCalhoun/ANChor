#!/bin/bash
set -e

echo "🔨 Building ANChor..."
swift build -c release

APP="ANChor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp .build/release/ANChor "$APP/Contents/MacOS/ANChor"

cat > "$APP/Contents/Info.plist" << 'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ANChor</string>
    <key>CFBundleIdentifier</key>
    <string>com.anchor.app</string>
    <key>CFBundleName</key>
    <string>ANChor</string>
    <key>CFBundleDisplayName</key>
    <string>ANChor</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>ANChor needs Bluetooth to communicate with your earbuds for noise control.</string>
</dict>
</plist>
XML

echo "✅ Created $APP"
echo "   Drag to /Applications or run: open $APP"
