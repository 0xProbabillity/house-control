#!/bin/bash
# Builds the iPhone app for the simulator and launches it there.
#   ./scripts/ios-sim.sh                 build + install + launch on the booted simulator
#   HOUSE_SCREEN=settings ./scripts/ios-sim.sh   …opening on a given screen (settings, pairing, smartlife, welcome, home)
# Any HOUSE_* variable set here is passed on to the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${DEVICE:-iPhone 17 Pro}"

if [ -z "${SKIP_WEB:-}" ]; then
  cd "$ROOT/web"
  [ -d node_modules ] || npm install
  npm run build --silent
fi

cd "$ROOT/ios"
xcodegen generate --quiet
xcodebuild -project HouseControl.xcodeproj -scheme HouseControl -configuration Debug \
  -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY=- build 2>&1 | grep -E "error|warning: |BUILD" | grep -v appintentsmetadataprocessor || true
APP="build/DerivedData/Build/Products/Debug-iphonesimulator/HouseControl.app"
[ -d "$APP" ] || { echo "Build failed"; exit 1; }

xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl install "$DEVICE" "$APP"
for name in $(compgen -v | grep '^HOUSE_' || true); do export "SIMCTL_CHILD_$name=${!name}"; done
xcrun simctl launch --terminate-running-process "$DEVICE" io.github.0xprobabillity.HouseControl
