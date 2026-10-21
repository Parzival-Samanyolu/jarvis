#!/bin/zsh
# Builds Mycroft.app (menu-bar only) next to the repo root. Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
swift build -c "$CONFIG" --product jarvis
APP=Mycroft.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/jarvis" "$APP/Contents/MacOS/jarvis"
[ -f assets/AppIcon.icns ] || swift scripts/make-icon.swift
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.jarvis.app</string>
  <key>CFBundleName</key><string>Mycroft</string>
  <key>CFBundleDisplayName</key><string>Mycroft</string>
  <key>CFBundleExecutable</key><string>jarvis</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Mycroft listens to your voice requests.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Mycroft turns your voice requests into text on this Mac.</string>
  <key>NSAppleEventsUsageDescription</key><string>Mycroft controls Notes and other apps for you.</string>
</dict></plist>
PLIST
# Ad-hoc signature (no Apple developer identity needed). Permissions may need re-granting after a rebuild.
codesign --force --deep --sign - "$APP"
echo "Built $PWD/$APP"
