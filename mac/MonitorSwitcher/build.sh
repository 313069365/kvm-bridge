#!/bin/sh
set -e
cd "$(dirname "$0")"

APP="KVMBridge.app"
EXEC="KVMBridge"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "compiling..."
swiftc -O -swift-version 5 \
    -framework Cocoa -framework CoreGraphics -framework ApplicationServices -framework Carbon \
    main.swift EventTapMonitor.swift KeyMap.swift RelayServer.swift StatusIcon.swift \
    Ddc.swift SwitchFlow.swift HotKeys.swift DebugServer.swift DisplayKick.swift Toast.swift Injector.swift \
    Discovery.swift \
    -o "$APP/Contents/MacOS/$EXEC"

# ---- 应用图标：渲染 1024 主图，缩放出 iconset，再打包成 icns ----
echo "rendering app icon..."
swift AppIconGen.swift AppIcon-master.png

ICONSET="AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

for spec in \
    "16 icon_16x16" \
    "32 icon_16x16@2x" \
    "32 icon_32x32" \
    "64 icon_32x32@2x" \
    "128 icon_128x128" \
    "256 icon_128x128@2x" \
    "256 icon_256x256" \
    "512 icon_256x256@2x" \
    "512 icon_512x512" \
    "1024 icon_512x512@2x"
do
    px=$(echo "$spec" | cut -d' ' -f1)
    name=$(echo "$spec" | cut -d' ' -f2)
    sips -z "$px" "$px" AppIcon-master.png --out "$ICONSET/$name.png" >/dev/null 2>&1
done

iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
echo "icon: $APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$EXEC</string>
    <key>CFBundleIdentifier</key>
    <string>com.kvmbridge.app</string>
    <key>CFBundleName</key>
    <string>KVM Bridge</string>
    <key>CFBundleDisplayName</key>
    <string>KVM Bridge</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.5.6</string>
    <key>CFBundleVersion</key>
    <string>18</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

chmod +x "$APP/Contents/MacOS/$EXEC"

# ---- DDC 工具：随 App 一起分发，运行时从 Resources 里找 ----
cp -f "../../vendor/m1ddc/m1ddc" "$APP/Contents/Resources/m1ddc"
chmod +x "$APP/Contents/Resources/m1ddc"
echo "bundled: $APP/Contents/Resources/m1ddc"

# ---- 签名：用固定证书，保证每次重编后辅助功能授权不失效 ----
KEYCHAIN="$HOME/Library/Keychains/kvm-signing.keychain-db"
IDENTITY="KVM Bridge Dev"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    security unlock-keychain -p "${KVM_SIGN_PASS:-kvm123}" "$KEYCHAIN" >/dev/null 2>&1 || true
    codesign --force --deep --sign "$IDENTITY" "$APP"
    echo "signed: $IDENTITY"
else
    codesign --force --deep --sign - "$APP"
    echo "signed: ad-hoc (授权会在每次重编后失效)"
fi

touch "$APP"
echo "built: $(pwd)/$APP"
