#!/bin/bash
# Archives the iPhone app for TestFlight / the App Store.
#   ./scripts/build-ios.sh            archive + export a signed .ipa into ios/build/export
#   ./scripts/build-ios.sh --upload   …and upload it to App Store Connect
#
# Needs: Xcode, xcodegen (brew install xcodegen), your team in ios/Config/Local.xcconfig
# (DEVELOPMENT_TEAM = …) and an App Store Connect API key:
#   ASC_KEY_ID      the key's ID; its file AuthKey_<id>.p8 lives in ~/.appstoreconnect/private_keys
#   ASC_ISSUER_ID   the issuer ID shown above the key list in App Store Connect
# The build number is CURRENT_PROJECT_VERSION in ios/Config/Base.xcconfig: raise it for every upload.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${ASC_KEY_ID:?Set ASC_KEY_ID to your App Store Connect API key ID}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to your App Store Connect issuer ID}"
KEY_FILE="${ASC_KEY_FILE:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
[ -f "$KEY_FILE" ] || { echo "No API key file at $KEY_FILE"; exit 1; }
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY_FILE"
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

echo "▸ Building web UI"
cd "$ROOT/web"
[ -d node_modules ] || npm install
npm run build --silent

echo "▸ Archiving"
cd "$ROOT/ios"
[ -f Config/Local.xcconfig ] || { echo "Create ios/Config/Local.xcconfig with: DEVELOPMENT_TEAM = <your team id>"; exit 1; }
xcodegen generate --quiet
rm -rf build/HouseControl.xcarchive build/export
xcodebuild archive -project HouseControl.xcodeproj -scheme HouseControl -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/HouseControl.xcarchive \
  -derivedDataPath build/DerivedData "${AUTH[@]}" 2>&1 | grep -E "error|ARCHIVE" || true
[ -d build/HouseControl.xcarchive ] || { echo "Archive failed"; exit 1; }

echo "▸ Exporting"
xcodebuild -exportArchive -archivePath build/HouseControl.xcarchive -exportPath build/export \
  -exportOptionsPlist Config/ExportOptions.plist "${AUTH[@]}" 2>&1 | grep -E "error|EXPORT" || true
[ -f build/export/HouseControl.ipa ] || { echo "Export failed"; exit 1; }
echo "✓ ios/build/export/HouseControl.ipa"

if [ "${1:-}" = "--upload" ]; then
  echo "▸ Uploading to App Store Connect"
  xcrun altool --upload-app -f build/export/HouseControl.ipa -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" 2>&1 | grep -E "UPLOAD|ERROR|error" || true
fi
