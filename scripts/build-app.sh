#!/usr/bin/env bash
#
# Builds "Claude Companion.app".
#
#   scripts/build-app.sh            build build/Claude Companion.app
#   scripts/build-app.sh --install  build, copy to ~/Applications and start it, and install the
#                                   `menu` command (for agents) to ~/.local/bin

set -euo pipefail
cd "$(dirname "$0")/.."

name="Claude Companion"
exe="ClaudeCompanion"
out="build/$name.app"
dest="$HOME/Applications/$name.app"

swift build -c release --product "$exe"
swift build -c release --product menu
bindir="$(swift build -c release --show-bin-path)"
bin="$bindir/$exe"

rm -rf "$out"
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
cp "$bin" "$out/Contents/MacOS/$exe"
cp Resources/Info.plist "$out/Contents/Info.plist"

# App icon, drawn by the app itself.
iconset="build/AppIcon.iconset"
rm -rf "$iconset" && mkdir -p "$iconset"
"$bin" --render-icon build/icon-1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d build/icon-1024.png --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$out/Contents/Resources/AppIcon.icns"

# Sign with your Apple Development identity when there is one: macOS then remembers the
# microphone and Ghostty permissions across rebuilds. Ad-hoc signing (the fallback) makes
# every build a new app to macOS, which asks again. CODESIGN_IDENTITY overrides the choice.
# The identity is picked by its hash: names with non-ASCII letters don't always match.
identity="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ { print $2; exit }')}"
if [[ -n "$identity" ]]; then
  codesign --force --sign "$identity" "$out" >/dev/null
  echo "Signed with $(security find-identity -v -p codesigning | awk -v h="$identity" '$2 == h { sub(/^[^"]*"/, ""); sub(/"$/, ""); print }')"
else
  codesign --force --sign - "$out" >/dev/null
  echo "Signed ad-hoc (macOS will ask for permissions again after each build)"
fi

if [[ "${1:-}" != "--install" && "${1:-}" != "--open" ]]; then
  echo "Built $out"
  exit 0
fi

mkdir -p "$HOME/Applications"
# Task Tracker now lives inside the companion: the standalone app would fight it over ⌃⌥T.
if pgrep -x TaskTracker >/dev/null; then
  osascript -e 'tell application id "local.TaskTracker" to quit' >/dev/null 2>&1 || pkill -x TaskTracker || true
  echo "Quit the standalone Task Tracker app; the companion has it built in now."
fi
if pgrep -x "$exe" >/dev/null; then
  osascript -e "tell application id \"local.claude-companion\" to quit" >/dev/null 2>&1 || pkill -x "$exe" || true
  sleep 1
fi
rm -rf "$dest"
cp -R "$out" "$dest"
echo "Installed $dest"
mkdir -p "$HOME/.local/bin"
cp "$bindir/menu" "$HOME/.local/bin/menu"
echo "Installed $HOME/.local/bin/menu"
open "$dest"
