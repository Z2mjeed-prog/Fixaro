#!/bin/bash
# Fixaro installer for Mac. Paste into Terminal:
#   curl -fsSL https://raw.githubusercontent.com/Z2mjeed-prog/Fixaro/main/install.sh | bash
# It gets Ollama (if you don't have it), installs Fixaro, offers to download the AI model, and opens Fixaro.
# It asks before installing anything. Paste the same line again any time to update Fixaro.
#   FIXARO_UPDATE=1   update Fixaro only, with no questions (Fixaro's "Update Fixaro…" menu item uses this)
#   FIXARO_BRANCH=x   install the test build of branch x (for testing before a release)
#   FIXARO_SOURCE=1   build Fixaro on this Mac instead of downloading the ready-made app
set -euo pipefail

REPO="Z2mjeed-prog/Fixaro"
BRANCH="${FIXARO_BRANCH:-main}"
UPDATE="${FIXARO_UPDATE:-}"
OLLAMA_URL="http://127.0.0.1:11434"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
say()  { printf '  %s\n' "$*"; }
fail() { printf '\n\033[31m%s\033[0m\n' "$*"; exit 1; }

# Questions read from the keyboard, even though this script arrives through a pipe
ask() {   # ask "Question?" → true for yes (Enter means yes)
  local answer=""
  if [ -r /dev/tty ]; then
    printf '  %s [Y/n] ' "$1"
    read -r answer < /dev/tty || answer=""
  fi
  case "$answer" in [nN]*) return 1 ;; *) return 0 ;; esac
}

ollama_up() { curl -fs -m 2 "$OLLAMA_URL/api/version" >/dev/null 2>&1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || fail "Fixaro needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."

if [ -n "$UPDATE" ]; then bold "Updating Fixaro · $(date)"; else bold "Installing Fixaro"; fi

# --- Ollama, the free app that runs the AI on your Mac -----------------------------------------------
ollama_app=""
for p in /Applications/Ollama.app "$HOME/Applications/Ollama.app"; do
  [ -d "$p" ] && ollama_app="$p"
done
if [ -z "$UPDATE" ]; then
  bold "Step 1 of 3: Ollama, the free app that runs the AI on your Mac"
  if [ -n "$ollama_app" ] || command -v ollama >/dev/null 2>&1; then
    say "Already installed."
  elif ask "Ollama isn't installed. Download and install it from ollama.com now?"; then
    say "Downloading Ollama…"
    curl -fL --progress-bar -o "$work/Ollama.dmg" "https://ollama.com/download/Ollama.dmg" \
      || fail "Couldn't download Ollama. Get it from https://ollama.com/download and run this again."
    mount="$(hdiutil attach -nobrowse -readonly "$work/Ollama.dmg" | awk -F '\t' '/\/Volumes\//{print $NF; exit}')"
    [ -d "$mount/Ollama.app" ] || fail "The Ollama download looked wrong. Get it from https://ollama.com/download and run this again."
    dest="/Applications"
    [ -w "$dest" ] || { dest="$HOME/Applications"; mkdir -p "$dest"; }
    rm -rf "$dest/Ollama.app"
    cp -R "$mount/Ollama.app" "$dest/"
    hdiutil detach -quiet "$mount" || true
    ollama_app="$dest/Ollama.app"
    say "Installed Ollama in $dest."
  else
    say "Skipped. Fixaro needs Ollama (or another local AI app) to rewrite text: https://ollama.com/download"
  fi
  # Make sure Ollama is running
  if [ -n "$ollama_app" ] && ! ollama_up; then
    open -g "$ollama_app" || true
    for _ in $(seq 1 30); do ollama_up && break; sleep 1; done
  fi
fi

# --- Fixaro ------------------------------------------------------------------------------------------
[ -z "$UPDATE" ] && bold "Step 2 of 3: Fixaro"
# Update the copy you already have: /Applications if it's there, else ~/Applications
if [ -d "/Applications/Fixaro.app" ]; then dest="/Applications"; else dest="$HOME/Applications"; fi
app=""

if [ -z "${FIXARO_SOURCE:-}" ]; then
  if [ "$BRANCH" = "main" ]; then url="https://github.com/$REPO/releases/latest/download/Fixaro-mac.zip"
  else url="https://github.com/$REPO/releases/download/test-build/Fixaro-mac.zip"; fi
  say "Downloading Fixaro…"
  # curl doesn't mark the download as "from the internet", so macOS opens it without a warning
  if curl -fsSL -o "$work/Fixaro-mac.zip" "$url" && ditto -x -k "$work/Fixaro-mac.zip" "$work/ready" \
     && [ -x "$work/ready/Fixaro.app/Contents/MacOS/Fixaro" ] && codesign --verify "$work/ready/Fixaro.app" 2>/dev/null; then
    app="$work/ready/Fixaro.app"
  else
    say "The ready-made app isn't available right now, so Fixaro will be built on your Mac instead."
  fi
fi

if [ -z "$app" ]; then
  # Building needs Apple's free developer tools
  if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
    [ -n "$UPDATE" ] && fail "Couldn't download the update, and Apple's developer tools aren't installed to build it."
    say "Building needs Apple's free developer tools. A window will ask to install them: click Install."
    xcode-select --install >/dev/null 2>&1 || true
    printf '  Waiting for the developer tools'
    until xcode-select -p >/dev/null 2>&1 && xcrun --find swiftc >/dev/null 2>&1; do printf '.'; sleep 10; done
    printf ' ready\n'
  fi
  say "Downloading the source…"
  curl -fsSL -o "$work/source.zip" "https://github.com/$REPO/archive/refs/heads/$BRANCH.zip" \
    || fail "Couldn't download Fixaro. Check your internet connection and try again."
  ditto -x -k "$work/source.zip" "$work/src"
  src="$(find "$work/src" -mindepth 1 -maxdepth 1 -type d | head -1)"
  say "Building it on your Mac…"
  bash "$src/scripts/package.sh" >"$work/build.log" 2>&1 \
    || { tail -20 "$work/build.log"; fail "The build failed. Please share the lines above in a GitHub issue."; }
  app="$src/dist/Fixaro.app"
fi

# Did the signature change? Then the old Accessibility permission no longer fits and is cleared,
# so Fixaro's welcome window can ask again. With the same signature it's kept.
old_req="$(codesign -d -r- "$dest/Fixaro.app" 2>/dev/null | grep designated || true)"
new_req="$(codesign -d -r- "$app" 2>/dev/null | grep designated || true)"
adhoc=""; codesign -dv "$app" 2>&1 | grep -q "Signature=adhoc" && adhoc=1

osascript -e 'quit app "Fixaro"' >/dev/null 2>&1 || true
pkill -x Fixaro 2>/dev/null || true
sleep 1
mkdir -p "$dest"
rm -rf "$dest/Fixaro.app"
ditto "$app" "$dest/Fixaro.app"
if [ -n "$adhoc" ] || [ "$old_req" != "$new_req" ]; then
  tccutil reset Accessibility io.github.z2mjeed-prog.fixaro >/dev/null 2>&1 || true
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dest/Fixaro.app/Contents/Info.plist" 2>/dev/null || echo "")"
say "Installed Fixaro $version in $dest."

# --- The AI model -------------------------------------------------------------------------------------
if [ -z "$UPDATE" ]; then
  bold "Step 3 of 3: the AI model"
  if curl -fs -m 3 "$OLLAMA_URL/api/tags" 2>/dev/null | grep -q '"name"'; then
    say "You already have a model. You can change it in Fixaro's menu: Settings → AI model."
  elif ollama_up; then
    gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
    if [ "$gb" -ge 15 ]; then model="qwen3.5:9b"; size="7.6 GB"; else model="nemotron-3-nano:4b"; size="2.9 GB"; fi
    if ask "Download the AI model for this Mac ($model, $size)? It only happens once."; then
      ollama_cli="$(command -v ollama || true)"
      [ -z "$ollama_cli" ] && [ -n "$ollama_app" ] && [ -x "$ollama_app/Contents/Resources/ollama" ] && ollama_cli="$ollama_app/Contents/Resources/ollama"
      if [ -n "$ollama_cli" ]; then
        "$ollama_cli" pull "$model" || say "The download didn't finish. Fixaro's welcome window can download it later."
      else
        say "Downloading (this can take a while)…"
        curl -fs -X POST "$OLLAMA_URL/api/pull" -d "{\"name\":\"$model\",\"stream\":false}" >/dev/null \
          || say "The download didn't finish. Fixaro's welcome window can download it later."
      fi
    else
      say "Skipped. Fixaro's welcome window can download one later."
    fi
  else
    say "Ollama isn't running, so this is skipped. Fixaro's welcome window can download a model once Ollama is open."
  fi
fi

open "$dest/Fixaro.app"

if [ -n "$UPDATE" ]; then
  say "Done."
else
  bold "Fixaro is installed"
  if [ -n "$adhoc" ] || [ "$old_req" != "$new_req" ]; then
    say "In Fixaro's welcome window, click Allow… and switch Fixaro on, so it can work in other apps."
  fi
  say "Then select text anywhere and press Control-Option-R (⌃⌥R) to polish it, or ⌃⌥S to rewrite it your way."
  say "Fixaro tells you in its menu when there's an update."
  echo
fi
