#!/bin/bash
# Packages BaseCamp Clone to run on other Macs: the app with the Homebrew libraries it uses (GDAL, PROJ, libmtp and
# theirs) and GDAL's and PROJ's data inside it, signed ad hoc, zipped, with the source code beside it as the GPL asks.
# The libraries run on the macOS version they were built for or later, so the app does too.
# Usage: Tools/package-release.sh [release|debug]. Writes build/package/. The app in build/ is left alone.
set -euo pipefail

configuration="${1:-release}"
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/package"
app="$out/BaseCamp Clone.app"
commit="$(git -C "$root" rev-parse --short HEAD)"
if [ "$configuration" = release ] && [ -n "$(git -C "$root" status --porcelain)" ]; then
    echo "Commit first: the source archive must match the app." >&2
    exit 1
fi

rm -rf "$out"
mkdir -p "$out"
"$root/Tools/make-app-bundle.sh" "$configuration" "$app"
python3 "$root/Tools/bundle-libraries.py" "$app"

# GDAL's data, and PROJ's without its optional transformation grids (hundreds of megabytes the app does not use).
resources="$app/Contents/Resources"
cp -R "$(brew --prefix gdal)/share/gdal" "$resources/gdal"
mkdir -p "$resources/proj"
find "$(brew --prefix proj)/share/proj/" -maxdepth 1 -type f ! -name '*.tif' -exec cp {} "$resources/proj/" \;
cp "$root/LICENSE" "$root/NOTICE.md" "$resources/"

# Shown in the About window.
cat > "$resources/Credits.html" <<HTML
<p style="font: 11px -apple-system; text-align: center">
BaseCamp Clone is free software under the GNU General Public License, version 3. Its complete source code comes
with the app, as <i>BaseCamp Clone source $commit.tar.gz</i>. It uses code from QMapShack and GPXSee (see NOTICE.md),
and the libraries listed in Contents/Resources/Licenses, under their own licences.
</p>
HTML

# The oldest macOS every bundled library runs on.
minimum="$(for file in "$app/Contents/MacOS/BaseCampApp" "$app/Contents/Frameworks/"*; do
    otool -l "$file" | awk '/LC_BUILD_VERSION/ { found = 1 } found && /minos/ { print $2; exit }'
done | sort -V | tail -1)"
plutil -replace LSMinimumSystemVersion -string "$minimum" "$app/Contents/Info.plist"

# Ad hoc: there is no Developer ID. Each Mac asks once before opening it (Control-click, Open).
codesign --force --sign - "$app/Contents/Frameworks/"*
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
ditto -c -k --keepParent "$app" "$out/BaseCamp Clone $version ($commit).zip"
git -C "$root" archive --format=tar.gz --prefix="BaseCamp Clone source $commit/" -o "$out/BaseCamp Clone source $commit.tar.gz" HEAD
echo "Packaged in $out (macOS $minimum or later):"
ls -lh "$out" | tail -n +2
