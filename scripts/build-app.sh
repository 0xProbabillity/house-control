#!/bin/bash
# Builds HouseControl.app: web UI (Vite) + native shell (SwiftPM), assembled into build/.
#   UNIVERSAL=1          one binary for Apple silicon and Intel Macs (what scripts/release-mac.sh ships)
#   CODESIGN_IDENTITY=…  sign with your certificate instead of ad hoc (see the end of this file)
#   APP_PATH=…           where to put the app (default build/HouseControl.app)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP_PATH:-$ROOT/build/HouseControl.app}"
# One version for both apps: the iPhone app's MARKETING_VERSION / CURRENT_PROJECT_VERSION.
VERSION="${VERSION:-$(sed -n 's/^MARKETING_VERSION *= *//p' "$ROOT/ios/Config/Base.xcconfig")}"
BUILD="${BUILD:-$(sed -n 's/^CURRENT_PROJECT_VERSION *= *//p' "$ROOT/ios/Config/Base.xcconfig")}"

echo "▸ Building web UI"
cd "$ROOT/web"
[ -d node_modules ] || npm install
npm run build --silent

echo "▸ Building native shell"
cd "$ROOT/macos"
ARCH_FLAGS=()
[ -n "${UNIVERSAL:-}" ] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} 2>&1 | grep -E "error|warning: unused|Build complete" || true
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/HouseControl"
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
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>© 0xProbability. MIT License.</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>House Control finds your Home Assistant and Hue Bridge on this network, and lets the iPhones you paired find this Mac to receive your floor plan.</string>
  <key>NSBonjourServices</key><array><string>_housecontrol._tcp</string><string>_hue._tcp</string><string>_home-assistant._tcp</string></array>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Ad-hoc by default. macOS ties permissions (the Local Network one that iPhone sync needs)
# to the signature, and an ad-hoc one changes with every build, so it asks again each time.
# CODESIGN_IDENTITY="Apple Development: …" (see `security find-identity -v -p codesigning`)
# signs with your own certificate and the permission sticks.
# A real identity also gets the hardened runtime and a secure timestamp, which notarization requires.
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP" || { echo "Signing failed"; exit 1; }
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (signing skipped)"
fi
echo "✓ Done: $APP"
