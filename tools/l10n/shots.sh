#!/bin/zsh
# Screenshots of one screen of the iPhone/iPad app in every language, for checking translations.
#
#   tools/l10n/shots.sh <device-udid> <out-dir> <name> [screen]
#
# Launches House Control on the (booted) simulator once per language, on a throw-away data folder
# so nothing of a real home is used, opened on `screen` (HOUSE_SCREEN: settings, pairing,
# smartlife, quickactions, homeassistant, hue, devices, language, editor, welcome, newhome, scan),
# waits, and saves <out-dir>/<name>-<lang>.png. Use a simulator of your own: other sessions test
# on the booted ones. The app has to be installed on it (scripts/ios-sim.sh).
# BUNDLE_ID overrides the app (default: the Smart Life edition's, as in ios/project-smartlife.yml);
# LANGS the languages ("en ja fr es de it el tr zh-Hant ru"); WAIT the seconds to wait (default 6).
# Taken from GlassDash.
set -e
U=$1; OUT=$2; NAME=$3; SCREEN=${4:-home}
APP=${BUNDLE_ID:-io.github.0xprobabillity.HouseControl}
mkdir -p "$OUT"
DATA=$(mktemp -d)
typeset -A LOCALE=(en en_GB ja ja_JP fr fr_FR es es_ES de de_DE it it_IT el el_GR tr tr_TR zh-Hant zh_TW ru ru_RU)
for lang in ${=LANGS:-en ja fr es de it el tr zh-Hant ru}; do
  xcrun simctl terminate "$U" "$APP" 2>/dev/null || true
  SIMCTL_CHILD_HOUSE_DATA_DIR="$DATA" SIMCTL_CHILD_HOUSE_SCREEN="$SCREEN" \
    xcrun simctl launch "$U" "$APP" -AppleLanguages "($lang)" -AppleLocale "${LOCALE[$lang]}" >/dev/null
  sleep ${WAIT:-6}
  xcrun simctl io "$U" screenshot "$OUT/$NAME-$lang.png" >/dev/null 2>&1
done
xcrun simctl terminate "$U" "$APP" 2>/dev/null || true
rm -rf "$DATA"
