#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
APP="$PWD/build/WindowHop Preview.app"
mkdir -p "$APP/Contents/MacOS"
# Keep the helper's deployment target aligned with Package.swift. This also
# allows the legacy CoreGraphics window-snapshot API on macOS 13–14.
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -O \
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
# Documents folders can add bundle-level Finder/FileProvider metadata after the
# recursive clear; remove it explicitly before ad-hoc signing.
xattr -c "$APP" 2>/dev/null || true
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$APP" 2>/dev/null || true
codesign --force --sign - "$APP"
if (( $# > 0 )); then
  "$APP/Contents/MacOS/WindowHopPreview" "$@"
else
  open "$APP"
fi
