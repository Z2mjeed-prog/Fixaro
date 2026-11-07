#!/bin/bash
# Builds Fixaro.app for Apple Silicon and Intel Macs and packs it as dist/Fixaro-mac.zip.
# GitHub runs this for every release. You can also run it on your Mac:  bash scripts/package.sh
# SIGN_ID="certificate name" signs with that certificate (so updates keep the Accessibility permission).
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(tr -d '[:space:]' < "$DIR/VERSION")}"
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
codesign --force --sign "${SIGN_ID:--}" "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority|Signature" || true

(cd "$OUT" && ditto -c -k --keepParent Fixaro.app Fixaro-mac.zip)
lipo -archs "$APP/Contents/MacOS/Fixaro"
ls -lh "$OUT"/Fixaro-mac.zip
echo "Done."
