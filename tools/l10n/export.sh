#!/bin/zsh
# Refreshes the String Catalogs of the iPhone/iPad app and its widgets from the code.
#
#   tools/l10n/export.sh
#
# Xcode fills the catalogs from what it compiles, and the two editions compile different code
# (Smart Life and the LiDAR scan only in project-smartlife.yml), so both are exported, one after
# the other, and normalize.py puts their keys together in the repository's layout. Each edition
# writes its own InfoPlist catalog (Resources/AppStore, Resources/SmartLife). Builds into
# ios/build/DerivedData-l10n; ends with the Smart Life edition generated, as scripts/build-ios.sh
# leaves it. Needs web/dist (npm --prefix web run build).
set -e
ROOT=${0:A:h:h:h}
TMP=$(mktemp -d)
cd "$ROOT/ios"
for spec in project.yml project-smartlife.yml; do
  echo "▸ Exporting the strings of $spec"
  xcodegen generate --spec $spec -q
  xcodebuild -exportLocalizations -project HouseControl.xcodeproj -scheme HouseControl \
    -localizationPath "$TMP/loc-$spec" -exportLanguage en -sdk iphonesimulator \
    -derivedDataPath build/DerivedData-l10n CODE_SIGN_IDENTITY=- -quiet
  mkdir -p "$TMP/$spec"
  cp Resources/Localizable.xcstrings "$TMP/$spec/app.xcstrings"
  cp ../widgets/Resources/Localizable.xcstrings "$TMP/$spec/widgets.xcstrings"
done
python3 "$ROOT/tools/l10n/normalize.py" "$TMP/project.yml" "$TMP/project-smartlife.yml"
rm -rf "$TMP"
