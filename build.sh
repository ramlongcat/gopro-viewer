#!/bin/zsh
# Builds GoProOffload and assembles a runnable .app bundle in dist/.
# Usage: ./build.sh [--open] [--zip]
#   --zip  also produce dist/GoProViewer.app.zip (the GitHub release asset)
set -e
cd "$(dirname "$0")"

# App version (semver) — single source of truth is the VERSION file.
VERSION="$(<VERSION)"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "VERSION must be semver (got: $VERSION)" >&2; exit 1; }

# Secret for the bundled Google OAuth client — lives in a git-ignored file
# and ships only inside the built app, never in the repo. Installed-app
# secrets aren't confidential (any shipped binary can be read), but public
# repo *text* trips GitHub/Google secret scanning.
GOOGLE_SECRET=""
[[ -f .google-client-secret ]] && GOOGLE_SECRET="$(<.google-client-secret)"
GOOGLE_SECRET="${GOOGLE_SECRET//[$'\r\n ']/}"
SECRET_PLIST=""
[[ -n "$GOOGLE_SECRET" ]] && SECRET_PLIST="<key>GoogleClientSecret</key><string>$GOOGLE_SECRET</string>"

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
cp Resources/profile.jpg "$APP/Contents/Resources/profile.jpg"

# launchd helper for the optional "open when a GoPro is plugged in" agent
# (Settings → Connection); lives in the bundle so the agent follows the app.
clang -O2 -o "$APP/Contents/MacOS/GoProUSBLauncher" tools/usb_launcher.c

# Unquoted heredoc so $VERSION expands; the plist contains no other $ / backticks.
cat > "$APP/Contents/Info.plist" <<PLIST
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
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    $SECRET_PLIST
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
codesign --force --sign - "$APP/Contents/MacOS/GoProUSBLauncher"
codesign --force --sign - "$APP"
echo "Built: $APP (v$VERSION)"

if [[ "$*" == *--zip* ]]; then
    ditto -c -k --keepParent "$APP" "dist/GoProViewer.app.zip"
    echo "Zipped: dist/GoProViewer.app.zip"
fi

if [[ "$*" == *--open* ]]; then
    open "$APP"
fi
