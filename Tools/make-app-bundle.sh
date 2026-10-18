#!/bin/bash
# Packages the BaseCampApp executable as a macOS app bundle, so macOS can activate it and
# scripts can find it by bundle identifier. Usage: Tools/make-app-bundle.sh [debug|release] [bundle path]
# The bundle links to Homebrew's libraries; Tools/package-release.sh makes one that runs on other Macs.
set -euo pipefail

configuration="${1:-debug}"
root="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$root" --configuration "$configuration" --product BaseCampApp

bundle="${2:-$root/build/HighCamp.app}"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS"
cp "$root/.build/$configuration/BaseCampApp" "$bundle/Contents/MacOS/BaseCampApp"

# The icon, in every size macOS asks for, from Artwork/AppIcon.png (1024 pixels, already on the macOS icon grid).
iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset" "$bundle/Contents/Resources"
for size in 16 32 128 256 512; do
    sips -z $size $size "$root/Artwork/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$root/Artwork/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$bundle/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$iconset")"

cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>BaseCampApp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.jjj.BaseCampClone</string>
    <key>CFBundleName</key><string>HighCamp</string>
    <key>CFBundleDisplayName</key><string>HighCamp</string>
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
