#!/bin/bash
# Packages the BaseCampApp executable as a macOS app bundle, so macOS can activate it and
# scripts can find it by bundle identifier. Usage: Tools/make-app-bundle.sh [debug|release] [bundle path]
# The bundle links to Homebrew's libraries; Tools/package-release.sh makes one that runs on other Macs.
set -euo pipefail

configuration="${1:-debug}"
root="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$root" --configuration "$configuration" --product BaseCampApp

bundle="${2:-$root/build/BaseCamp Clone.app}"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS"
cp "$root/.build/$configuration/BaseCampApp" "$bundle/Contents/MacOS/BaseCampApp"

cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>BaseCampApp</string>
    <key>CFBundleIdentifier</key><string>com.jjj.BaseCampClone</string>
    <key>CFBundleName</key><string>BaseCamp Clone</string>
    <key>CFBundleDisplayName</key><string>BaseCamp Clone</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSLocationUsageDescription</key><string>To open the map around where you are.</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>To open the map around where you are.</string>
</dict>
</plist>
PLIST

echo "Built $bundle"
