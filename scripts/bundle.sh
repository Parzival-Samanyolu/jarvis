#!/bin/zsh
# Builds Jarvis.app (menu-bar only) next to the repo root. Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
swift build -c "$CONFIG" --product jarvis
APP=Jarvis.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/jarvis" "$APP/Contents/MacOS/jarvis"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.jarvis.app</string>
  <key>CFBundleName</key><string>Jarvis</string>
  <key>CFBundleExecutable</key><string>jarvis</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Jarvis listens to your voice requests.</string>
  <key>NSAppleEventsUsageDescription</key><string>Jarvis controls Notes and other apps for you.</string>
</dict></plist>
PLIST
# Ad-hoc signature (no Apple developer identity needed). Permissions may need re-granting after a rebuild.
codesign --force --deep --sign - "$APP"
echo "Built $PWD/$APP"
