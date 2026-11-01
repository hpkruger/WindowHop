#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
SIGNING_CONFIG="$HOME/Library/Application Support/WindowHop/signing-identity"
SIGN_IDENTITY="${WINDOWHOP_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" && -e "$SIGNING_CONFIG" ]]; then
  SIGN_IDENTITY="$(cat "$SIGNING_CONFIG")"
  if [[ ! "$SIGN_IDENTITY" =~ '^[[:xdigit:]]{40}$' ]]; then
    print -u2 -- "Invalid signing identity in $SIGNING_CONFIG; refusing to fall back to ad-hoc signing."
    exit 1
  fi
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
BUILD_ARGS=()
if [[ -n "${WINDOWHOP_BUILD_PATH:-}" ]]; then
  BUILD_ARGS+=(--scratch-path "$WINDOWHOP_BUILD_PATH")
fi
swift build -c release "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build -c release "${BUILD_ARGS[@]}" --show-bin-path)"
APP="${WINDOWHOP_APP_PATH:-$PWD/build/WindowHop.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swift scripts/make-icon.swift "$PWD/build/AppIcon.iconset"
iconutil -c icns "$PWD/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/WindowHop" "$APP/Contents/MacOS/WindowHop"
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
# Reuse this Mac's saved certificate unless explicitly overridden. codesign fails
# if the configured private key is missing; never silently replace it with ad-hoc signing.
xattr -cr "$APP"
codesign --force --sign "$SIGN_IDENTITY" --identifier local.hanskruger.WindowHop "$APP"
print -r -- "$APP"
