#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-0.3.0}"
out="dist/LiteBar.app"
rm -rf dist && mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"

swift build -c release --jobs 1
cp .build/release/LiteBar "$out/Contents/MacOS/LiteBar"
mkdir -p "$out/Contents/Helpers"
cp .build/release/LiteBarCapture "$out/Contents/Helpers/LiteBarCapture"

cp -R .build/release/LiteBar_LiteBar.bundle "$out/Contents/Resources/"

.build/release/LiteBar --make-icon dist/AppIcon.icns
mkdir -p "$out/Contents/Resources"
cp dist/AppIcon.icns "$out/Contents/Resources/AppIcon.icns"

cat > "$out/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LiteBar</string>
    <key>CFBundleDisplayName</key><string>LiteBar</string>
    <key>CFBundleIdentifier</key><string>dev.ibrahime.LiteBar</string>
    <key>CFBundleExecutable</key><string>LiteBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

identity="${CODESIGN_IDENTITY:--}"
codesign --force -s "${identity:--}" "$out/Contents/Helpers/LiteBarCapture"
codesign --force -s "${identity:--}" "$out"
echo "Packaged $out (signed: ${identity:-ad-hoc})"
