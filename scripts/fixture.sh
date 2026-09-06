#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
APP="$PWD/build/WindowHop Fixture.app"
ditto build/WindowHop.app "$APP"
plutil -replace CFBundleIdentifier -string local.hanskruger.WindowHop.Fixture "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string 'WindowHop Fixture' "$APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string 'WindowHop Fixture' "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign - "$APP"
open "$APP" --args --fixture
