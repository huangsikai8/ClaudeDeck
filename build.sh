#!/bin/bash
# Builds ClaudeDeck and installs it to /Applications.
#
# Signed with a stable identity where one exists, so that rebuilds keep the
# Accessibility grant instead of registering as a new app each time.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/ClaudeDeck.app"
IDENTITY="${CLAUDEDECK_IDENTITY:-WindowDeck Dev}"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
	echo "==> identity '$IDENTITY' not found; signing ad-hoc (Accessibility grant resets each build)"
	IDENTITY="-"
fi

echo "==> compiling"
mkdir -p "$SRC_DIR/build"
swiftc -O -parse-as-library -o "$SRC_DIR/build/ClaudeDeck" "$SRC_DIR/app/main.swift" \
	-framework AppKit -framework SwiftUI

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC_DIR/build/ClaudeDeck" "$APP/Contents/MacOS/ClaudeDeck"
cp "$SRC_DIR/Info.plist" "$APP/Contents/Info.plist"

# macOS 26 resolves icons for system UI from an IconImageStack, which only an
# Icon Composer .icon compiles to; a legacy .appiconset leaves those places
# blank while Finder quietly falls back to the .icns and looks correct.
echo "==> compiling icon"
ICON="$SRC_DIR/build/AppIcon.icon"
rm -rf "$ICON"
mkdir -p "$ICON/Assets" "$SRC_DIR/build/assets"
cp "$SRC_DIR/AppIcon.icon/icon.json" "$ICON/icon.json"
cp "$SRC_DIR/icon-1024.png" "$ICON/Assets/icon-1024.png"
xcrun actool "$ICON" --compile "$SRC_DIR/build/assets" \
	--platform macosx --minimum-deployment-target 13.0 --app-icon AppIcon \
	--output-partial-info-plist "$SRC_DIR/build/assets/partial.plist" >/dev/null
cp "$SRC_DIR/build/assets/Assets.car" "$APP/Contents/Resources/Assets.car"

# actool emits a truncated .icns (256px max), leaving Finder nothing to draw at
# larger sizes. Build the full set from the master artwork instead.
echo "==> building icns"
ICONSET="$SRC_DIR/build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for SZ in 16 32 128 256 512; do
	sips -s format png -z $SZ $SZ "$SRC_DIR/icon-1024.png" \
		--out "$ICONSET/icon_${SZ}x${SZ}.png" >/dev/null
	sips -s format png -z $((SZ * 2)) $((SZ * 2)) "$SRC_DIR/icon-1024.png" \
		--out "$ICONSET/icon_${SZ}x${SZ}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> signing as '$IDENTITY'"
codesign --force --sign "$IDENTITY" --identifier com.sikaihuang.claudedeck "$APP"
codesign --verify --verbose=1 "$APP"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "==> done: $APP"
