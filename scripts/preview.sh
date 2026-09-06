#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
APP="$PWD/build/WindowHop Preview.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -swift-version 5 -O \
  Sources/WindowHop/KeyboardTap.swift \
  Sources/WindowHop/WindowCatalog.swift \
  Sources/WindowHop/SwitcherUI.swift \
  scripts/preview/main.swift \
  -o "$APP/Contents/MacOS/WindowHopPreview"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WindowHopPreview</string>
<key>CFBundleIdentifier</key><string>local.windowhop.documentation-preview</string>
<key>CFBundleName</key><string>WindowHop Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
xattr -cr "$APP"
codesign --force --sign - "$APP"
if (( $# > 0 )); then
  "$APP/Contents/MacOS/WindowHopPreview" "$@"
else
  open "$APP"
fi
