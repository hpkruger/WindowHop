#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
APP="$PWD/build/WindowHop.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swift scripts/make-icon.swift "$PWD/build/AppIcon.iconset"
iconutil -c icns "$PWD/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/WindowHop "$APP/Contents/MacOS/WindowHop"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WindowHop</string>
<key>CFBundleIdentifier</key><string>local.hanskruger.WindowHop</string>
<key>CFBundleName</key><string>WindowHop</string>
<key>CFBundleDisplayName</key><string>WindowHop</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Set WINDOWHOP_SIGN_IDENTITY to a development identity for stable permissions across rebuilds.
xattr -cr "$APP"
codesign --force --sign "${WINDOWHOP_SIGN_IDENTITY:--}" --identifier local.hanskruger.WindowHop "$APP"
print -r -- "$APP"
