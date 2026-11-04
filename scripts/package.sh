#!/bin/bash
# Builds Fixaro.app for Apple Silicon and Intel Macs, and packs it as a .dmg and a .zip in dist/.
# GitHub runs this for every release. You can also run it on your Mac:  bash scripts/package.sh [version]
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DIR/Info.plist")}"
VERSION="${VERSION#v}"
OUT="$DIR/dist"
APP="$OUT/Fixaro.app"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$DIR"/Resources/* "$APP/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

echo "Compiling Fixaro $VERSION for Apple Silicon and Intel..."
SDK="$(xcrun --sdk macosx --show-sdk-path)"
for ARCH in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target "$ARCH-apple-macos14.0" -sdk "$SDK" \
    "$DIR/Sources/main.swift" -o "$OUT/Fixaro-$ARCH"
done
lipo -create "$OUT/Fixaro-arm64" "$OUT/Fixaro-x86_64" -output "$APP/Contents/MacOS/Fixaro"
rm "$OUT/Fixaro-arm64" "$OUT/Fixaro-x86_64"
codesign --force --sign - "$APP"

# A .zip, and a .dmg whose window says "Drag Fixaro into Applications"
(cd "$OUT" && ditto -c -k --keepParent Fixaro.app "Fixaro-$VERSION.zip")
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
DMG="$OUT/Fixaro-$VERSION.dmg"
BG="$OUT/background.tiff"
tiffutil -cathidpicheck "$DIR/scripts/dmg/background.png" "$DIR/scripts/dmg/background@2x.png" -out "$BG" >/dev/null 2>&1 \
  || cp "$DIR/scripts/dmg/background.png" "$BG"
if command -v create-dmg >/dev/null 2>&1 && create-dmg --volname "Fixaro" --background "$BG" \
     --window-pos 200 120 --window-size 600 400 --icon-size 128 \
     --icon "Fixaro.app" 160 190 --hide-extension "Fixaro.app" --app-drop-link 440 190 \
     "$DMG" "$STAGE" >/dev/null; then
  echo "Made the styled .dmg"
else
  echo "create-dmg not available (brew install create-dmg): making a plain .dmg"
  rm -f "$DMG"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Fixaro" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
fi
rm -rf "$STAGE" "$BG"

lipo -archs "$APP/Contents/MacOS/Fixaro"
ls -lh "$OUT"/*.dmg "$OUT"/*.zip
echo "Done."
