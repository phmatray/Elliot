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
swift build -c "$CONFIG" --product elliot-icon
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

# Read from the Swift source rather than written twice. A plist that names a
# version the code does not is worse than no version at all: it is the one thing
# a bug report from the field is trusted on.
VERSION="$(sed -n 's/.*marketingVersion = "\(.*\)".*/\1/p' "$ROOT/ElliotKit/Sources/ElliotIPC/Protocol.swift")"
if [ -z "$VERSION" ]; then
  echo "✗ Could not read ElliotBuild.marketingVersion from Sources/ElliotIPC/Protocol.swift" >&2
  exit 1
fi

echo "▸ Assembling $APP ($VERSION)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/ElliotApp" "$APP/Contents/MacOS/Elliot"
cp "$BIN/elliot-mcp" "$APP/Contents/MacOS/elliot-mcp"

# The icon is rendered from ElliotMark rather than committed as a blob, so it
# cannot fall behind the mark the app itself draws. `iconutil` ships with macOS.
#
# The temporary directory is held in its own variable and removed by name. The
# obvious spelling — building "$(mktemp -d)/AppIcon.iconset" and later removing
# "$(dirname …)" — reconstructs the path to a `rm -rf` argument, and if mktemp
# ever produced nothing that argument is `/`. `set -e` would abort at the
# assignment first, but that is a poor thing to bet a recursive delete on.
ICONDIR="$(mktemp -d)"
"$BIN/elliot-icon" iconset "$ICONDIR/AppIcon.iconset"
iconutil -c icns "$ICONDIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONDIR"

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Elliot</string>
  <key>CFBundleDisplayName</key>     <string>Elliot</string>
  <key>CFBundleExecutable</key>      <string>Elliot</string>
  <key>CFBundleIconFile</key>        <string>AppIcon</string>
  <key>CFBundleIdentifier</key>      <string>dev.phmatray.elliot</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>$VERSION</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <!-- Mirrors platforms: [.macOS(.v15)] in Package.swift, and is UNVERIFIED for the same reason:
       nobody has launched this bundle on macOS 15. That is a deployment claim, separate from the
       swift-tools-version floor #116 corrected, and it is tracked as #142. Read the comment above
       platforms: before changing this number — the two must move together or not at all. -->
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
