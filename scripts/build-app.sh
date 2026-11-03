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

codesign --force --sign - "$out" >/dev/null

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
