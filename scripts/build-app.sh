#!/bin/bash
# Builds HouseControl.app: web UI (Vite) + native shell (SwiftPM), assembled into build/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/HouseControl.app"

echo "▸ Building web UI"
cd "$ROOT/web"
[ -d node_modules ] || npm install
npm run build --silent

echo "▸ Building native shell"
cd "$ROOT/macos"
swift build -c release 2>&1 | grep -E "error|warning: unused|Build complete" || true
BIN="$(swift build -c release --show-bin-path)/HouseControl"
[ -x "$BIN" ] || { echo "Swift build failed"; exit 1; }

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HouseControl"
cp -R "$ROOT/web/dist" "$APP/Contents/Resources/web"
[ -f "$ROOT/macos/AppIcon.icns" ] && cp "$ROOT/macos/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>House Control</string>
  <key>CFBundleDisplayName</key><string>House Control</string>
  <key>CFBundleIdentifier</key><string>io.github.0xprobabillity.HouseControl</string>
  <key>CFBundleExecutable</key><string>HouseControl</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>House Control lets the iPhones you paired find this Mac on your network to receive your floor plan.</string>
  <key>NSBonjourServices</key><array><string>_housecontrol._tcp</string></array>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (ad-hoc signing skipped)"
echo "✓ Done: $APP"
