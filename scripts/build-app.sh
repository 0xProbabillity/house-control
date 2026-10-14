#!/bin/bash
# Builds HouseControl.app: web UI (Vite) + native shell (SwiftPM), assembled into build/.
#   UNIVERSAL=1          one binary for Apple silicon and Intel Macs (what scripts/release-mac.sh ships)
#   CODESIGN_IDENTITY=…  sign with your certificate instead of ad hoc (see the end of this file)
#   APP_PATH=…           where to put the app (default build/HouseControl.app)
#   SKIP_WIDGETS=1       leave out the desktop and Control Center widgets (they need Xcode and xcodegen)
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

# The widgets share an App Group with the app. On the Mac its id carries the signing team,
# taken from the certificate; an ad-hoc build has no team (see docs/widgets.md).
TEAM=""
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  # CODESIGN_IDENTITY may be the certificate's name or its SHA-1.
  NAME="$(security find-identity -v -p codesigning | grep -F "$CODESIGN_IDENTITY" | sed -n 's/.*"\(.*\)"/\1/p' | head -1)" || true
  TEAM="$(security find-certificate -c "${NAME:-$CODESIGN_IDENTITY}" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p')" || true
fi
GROUP="${TEAM:+$TEAM.}io.github.0xprobabillity.HouseControl"

if [ -z "${SKIP_WIDGETS:-}" ]; then
  echo "▸ Building widgets"
  cd "$ROOT/widgets"
  xcodegen generate --quiet
  WIDGET_ARCHS=()
  [ -n "${UNIVERSAL:-}" ] && WIDGET_ARCHS=(ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO)
  xcodebuild -project HouseWidgetsMac.xcodeproj -scheme HouseWidgets -configuration Release \
    -derivedDataPath build/DerivedData -destination 'generic/platform=macOS' \
    CODE_SIGN_IDENTITY="${CODESIGN_IDENTITY:--}" DEVELOPMENT_TEAM="$TEAM" ${WIDGET_ARCHS[@]+"${WIDGET_ARCHS[@]}"} \
    build 2>&1 | grep -E "error:|BUILD FAILED" || true
  APPEX="$ROOT/widgets/build/DerivedData/Build/Products/Release/HouseWidgets.appex"
  [ -d "$APPEX" ] || { echo "Widget build failed"; exit 1; }
fi

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HouseControl"
cp -R "$ROOT/web/dist" "$APP/Contents/Resources/web"
[ -f "$ROOT/macos/AppIcon.icns" ] && cp "$ROOT/macos/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
if [ -n "${APPEX:-}" ]; then
  mkdir -p "$APP/Contents/PlugIns"
  cp -R "$APPEX" "$APP/Contents/PlugIns/"
fi
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
  <key>HouseAppGroup</key><string>$GROUP</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>io.github.0xprobabillity.HouseControl.open</string>
    <key>CFBundleURLSchemes</key><array><string>housecontrol</string></array>
  </dict></array>
</dict>
</plist>
PLIST
# Ad-hoc by default. macOS ties permissions (the Local Network one that iPhone sync needs)
# to the signature, and an ad-hoc one changes with every build, so it asks again each time.
# CODESIGN_IDENTITY="Apple Development: …" (see `security find-identity -v -p codesigning`)
# signs with your own certificate and the permission sticks.
# A real identity also gets the hardened runtime and a secure timestamp, which notarization requires.
# The widget extension inside was signed by xcodebuild with its own (sandbox) entitlements;
# the app gets the App Group it shares with it.
ENTITLEMENTS="$(mktemp -d)/HouseControl.entitlements"
cat > "$ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.application-groups</key><array><string>$GROUP</string></array>
</dict></plist>
ENT
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$CODESIGN_IDENTITY" "$APP" \
    || { echo "Signing failed"; exit 1; }
else
  codesign --force --entitlements "$ENTITLEMENTS" --sign - "$APP" >/dev/null 2>&1 || echo "  (signing skipped)"
fi
rm -rf "$(dirname "$ENTITLEMENTS")"
echo "✓ Done: $APP"
