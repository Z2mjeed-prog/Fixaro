#!/bin/bash
# Fixaro: build, install and launch.
# Run from anywhere:  bash path/to/fixaro/build.sh
cd "$(dirname "$0")" || exit 1
DIR="$(pwd)"
APP="Fixaro"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DIR/Info.plist")"
BUILD="$DIR/build/$APP.app"
DEST="$HOME/Applications/$APP.app"
LOG="$HOME/Library/Logs/$APP.log"
# For development: FIXARO_DEV_LOG_DIR=/some/folder bash build.sh  (log goes there instead)
if [ -n "$FIXARO_DEV_LOG_DIR" ]; then LOG="$FIXARO_DEV_LOG_DIR/fixaro.log"; fi
mkdir -p "$DIR/build"
exec > >(tee "$DIR/build/build.log") 2>&1

echo "== Fixaro build · $(date) =="
echo "macOS $(sw_vers -productVersion) · $(uname -m)"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo ""
  echo ">> Apple's developer tools are missing. A window will pop up: click Install."
  echo ">> When it finishes, run this same command again."
  xcode-select --install
  exit 1
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"

# Ollama check (not required to build, but Fixaro needs it for AI fixes and rephrasing)
if TAGS="$(curl -s --max-time 2 http://127.0.0.1:11434/api/tags)"; then
  echo "Ollama: running"
  MEM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
  if [ "$MEM_GB" -ge 18 ]; then REC="qwen3.5:4b gemma4:e4b"; elif [ "$MEM_GB" -ge 16 ]; then REC="qwen3.5:4b"; else REC="qwen3.5:2b"; fi
  for m in $REC; do
    echo "$TAGS" | grep -q "\"$m\"" || echo "   suggested for your ${MEM_GB} GB Mac:  ollama pull $m   (any model works; see README)"
  done
else
  echo "Ollama: not running. Fixaro will use the Mac's spell checker only until you install and open Ollama (ollama.com)."
fi

OSVER="$(sw_vers -productVersion | cut -d. -f1-2)"
rm -rf "$DIR/build/$APP.app"
mkdir -p "$BUILD/Contents/MacOS"
cp "$DIR/Info.plist" "$BUILD/Contents/Info.plist"
if [ -n "$FIXARO_DEV_LOG_DIR" ]; then
  /usr/libexec/PlistBuddy -c "Add :FixaroDevLogDir string $FIXARO_DEV_LOG_DIR" "$BUILD/Contents/Info.plist"
fi

echo ""
echo "Compiling..."
if ! xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos$OSVER" -sdk "$SDK" \
     "$DIR/Sources/main.swift" -o "$BUILD/Contents/MacOS/$APP"; then
  echo ""
  echo "BUILD FAILED. Please open an issue on GitHub with the error above."
  exit 1
fi
codesign --force --sign - "$BUILD" >/dev/null 2>&1 || { echo "Signing failed"; exit 1; }

echo "Installing to ~/Applications ..."
pkill -x "$APP" 2>/dev/null; sleep 1
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$BUILD" "$DEST"
# A rebuilt app needs fresh permission; this clears Fixaro's old entry only.
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
: > "$LOG"
open "$DEST"

echo ""
echo ">> NEXT: macOS will ask to allow Fixaro. Click 'Open System Settings' and turn Fixaro ON"
echo ">>       under Privacy & Security > Accessibility."
echo ""
echo "Waiting for the app to start..."
sleep 10
echo "== App log =="
cat "$LOG"
echo "== Done =="
