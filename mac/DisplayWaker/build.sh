#!/bin/sh
set -e
cd "$(dirname "$0")"

APP="DisplayWaker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 \
    -framework Cocoa -framework CoreGraphics \
    main.swift -o "$APP/Contents/MacOS/DisplayWaker"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>DisplayWaker</string>
    <key>CFBundleIdentifier</key>
    <string>com.kvmbridge.displaywaker</string>
    <key>CFBundleName</key>
    <string>DisplayWaker</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

chmod +x "$APP/Contents/MacOS/DisplayWaker"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "codesign skipped"

echo "built: $(pwd)/$APP"
