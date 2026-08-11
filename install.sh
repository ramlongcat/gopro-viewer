#!/bin/bash
# Installs the latest GoProViewer release into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/ramlongcat/gopro-viewer/main/install.sh | bash
#
# Downloads GoProViewer.app.zip from the latest GitHub release, replaces any
# existing copy, and removes the quarantine flag (the app is ad-hoc signed, so
# Gatekeeper would otherwise report it as damaged).
set -euo pipefail

REPO="ramlongcat/gopro-viewer"
APP="GoProViewer.app"
ZIP_URL="https://github.com/$REPO/releases/latest/download/GoProViewer.app.zip"

[[ "$(uname -sm)" == "Darwin arm64" ]] || { echo "GoProViewer runs on Apple Silicon Macs only." >&2; exit 1; }
os_major="$(sw_vers -productVersion | cut -d. -f1)"
(( os_major >= 14 )) || { echo "GoProViewer needs macOS 14 (Sonoma) or newer." >&2; exit 1; }

dest="/Applications"
[[ -w "$dest" ]] || { dest="$HOME/Applications"; mkdir -p "$dest"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading GoProViewer (latest release)…"
curl -fL --progress-bar "$ZIP_URL" -o "$tmp/app.zip"
ditto -x -k "$tmp/app.zip" "$tmp/unzipped"
[[ -d "$tmp/unzipped/$APP" ]] || { echo "Unexpected archive layout: $APP not found in download." >&2; exit 1; }

# Gracefully quit a running copy before replacing it.
if pgrep -xq GoProOffload; then
  osascript -e 'tell application "GoProViewer" to quit' >/dev/null 2>&1 || true
  for _ in {1..10}; do pgrep -xq GoProOffload || break; sleep 0.5; done
fi

rm -rf "${dest:?}/$APP"
mv "$tmp/unzipped/$APP" "$dest/$APP"
xattr -dr com.apple.quarantine "$dest/$APP" 2>/dev/null || true

echo "Installed: $dest/$APP"
echo "First launch will ask for Local Network permission — allow it; that's the USB link to the camera."
open "$dest/$APP"
