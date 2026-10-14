#!/bin/bash
# Builds the Mac app people download: universal, signed with a Developer ID, notarized by
# Apple and packed into a disk image, so it opens on any Mac without a warning.
#   ./scripts/release-mac.sh             build/HouseControl-<version>.dmg
#   ./scripts/release-mac.sh --publish   …and attach it to a GitHub release v<version> (needs `gh`)
#
# Needs:
#   a "Developer ID Application" certificate in your keychain (Xcode → Settings → Accounts →
#     Manage Certificates → + → Developer ID Application). Picked up by itself, or set CODESIGN_IDENTITY.
#   for notarization, either an App Store Connect API key
#     ASC_KEY_ID, ASC_ISSUER_ID (key file AuthKey_<id>.p8 in ~/.appstoreconnect/private_keys)
#   or a profile stored with `xcrun notarytool store-credentials`: NOTARY_PROFILE=<name>.
#   uv (brew install uv), which runs dmgbuild to lay out the disk image.
# UNSIGNED=1 skips signing and notarization: a disk image for testing the layout only —
# macOS will refuse to open the app in it until the user allows it in System Settings.
# The version is MARKETING_VERSION in ios/Config/Base.xcconfig, shared with the iPhone app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sed -n 's/^MARKETING_VERSION *= *//p' "$ROOT/ios/Config/Base.xcconfig")"
# Its own folder, so a release build never replaces the app you run from build/.
# The bundle is named with a space here, which is what people see in Applications.
APP="$ROOT/build/release/House Control.app"
DMG="$ROOT/build/HouseControl-$VERSION.dmg"
command -v uvx >/dev/null || { echo "Install uv first: brew install uv"; exit 1; }

if [ -z "${UNSIGNED:-}" ]; then
  if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
  fi
  [ -n "$CODESIGN_IDENTITY" ] || {
    echo "No Developer ID Application certificate in the keychain."
    echo "Create one in Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application,"
    echo "or run with UNSIGNED=1 for a test image."
    exit 1
  }
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY=(--keychain-profile "$NOTARY_PROFILE")
  else
    : "${ASC_KEY_ID:?Set ASC_KEY_ID and ASC_ISSUER_ID (or NOTARY_PROFILE) for notarization}"
    : "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to your App Store Connect issuer ID}"
    KEY_FILE="${ASC_KEY_FILE:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
    [ -f "$KEY_FILE" ] || { echo "No API key file at $KEY_FILE"; exit 1; }
    NOTARY=(--key "$KEY_FILE" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
  fi
  echo "▸ Signing as $CODESIGN_IDENTITY"
  export CODESIGN_IDENTITY
fi

UNIVERSAL=1 APP_PATH="$APP" "$ROOT/scripts/build-app.sh"
lipo -archs "$APP/Contents/MacOS/HouseControl"

[ -f "$ROOT/macos/dmg-background.tiff" ] || "$ROOT/scripts/make-dmg-background.swift"
echo "▸ Packing $DMG"
rm -f "$DMG"
uvx --quiet dmgbuild -s "$ROOT/scripts/dmg-settings.py" -D app="$APP" -D root="$ROOT" "House Control $VERSION" "$DMG"

if [ -z "${UNSIGNED:-}" ]; then
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
  echo "▸ Notarizing (usually a few minutes)"
  xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait --timeout 30m | tee "$ROOT/build/notary.log"
  grep -q "status: Accepted" "$ROOT/build/notary.log" || {
    id="$(sed -n 's/^ *id: //p' "$ROOT/build/notary.log" | head -1)"
    echo "Notarization failed. Details: xcrun notarytool log $id ${NOTARY[*]}"
    exit 1
  }
  xcrun stapler staple "$DMG"
  echo "▸ Checking it the way Gatekeeper will"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "✓ $DMG"

if [ "${1:-}" = "--publish" ]; then
  [ -z "${UNSIGNED:-}" ] || { echo "Refusing to publish an unsigned image"; exit 1; }
  echo "▸ Publishing release v$VERSION"
  cd "$ROOT"
  gh release create "v$VERSION" "$DMG" "$DMG.sha256" --title "House Control $VERSION" --generate-notes
fi
