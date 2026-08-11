#!/bin/zsh
# Builds GoProOffload and assembles a runnable .app bundle in dist/.
# Usage: ./build.sh [--open]
set -e
cd "$(dirname "$0")"

swift build -c release

APP="dist/GoProViewer.app"
BIN=".build/release/GoProOffload"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GoProOffload"
if [[ ! -f Resources/AppIcon.icns ]]; then
    swift tools/make_icon.swift Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>GoProOffload</string>
    <key>CFBundleIdentifier</key><string>com.rama.gopro-offload</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>GoProViewer</string>
    <key>CFBundleDisplayName</key><string>GoProViewer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>GoPro Offload talks to your GoPro over its USB network link to browse and transfer media.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
</dict>
</plist>
PLIST

echo -n 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP"
echo "Built: $APP"

if [[ "$1" == "--open" ]]; then
    open "$APP"
fi
