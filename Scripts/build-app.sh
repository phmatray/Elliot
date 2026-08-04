#!/bin/bash
# Assembles Elliot.app from the SwiftPM products.
#
# SwiftPM cannot emit a bundle, and a hand-written .xcodeproj is a lot of
# generated XML to maintain for two targets. This script does the only three
# things the bundle actually needs: a layout, an Info.plist, and the MCP helper
# copied in beside the app binary so `claude mcp add` can point at a stable path.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/dist/Elliot.app"

echo "▸ Building ($CONFIG)…"
cd "$ROOT/ElliotKit"
swift build -c "$CONFIG" --product ElliotApp
swift build -c "$CONFIG" --product elliot-mcp
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/ElliotApp" "$APP/Contents/MacOS/Elliot"
cp "$BIN/elliot-mcp" "$APP/Contents/MacOS/elliot-mcp"

cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Elliot</string>
  <key>CFBundleDisplayName</key>     <string>Elliot</string>
  <key>CFBundleExecutable</key>      <string>Elliot</string>
  <key>CFBundleIdentifier</key>      <string>dev.phmatray.elliot</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>0.1.0</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>LSMinimumSystemVersion</key>  <string>15.0</string>
  <key>NSHighResolutionCapable</key> <true/>
  <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for local use, and keeps macOS from complaining
# about an unsigned bundle spawning children.
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/elliot-mcp" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || true

echo "▸ Done: $APP"
echo
echo "Launch it from the Finder — not from Xcode or a terminal — so it runs"
echo "without inheriting your shell PATH, which is the condition the preflight"
echo "checks actually have to survive:"
echo "    open $APP"
echo
echo "Register the MCP helper with Claude Code:"
echo "    claude mcp add elliot -s user -- $APP/Contents/MacOS/elliot-mcp"
