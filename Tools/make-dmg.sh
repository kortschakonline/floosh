#!/bin/zsh
# Baut den DMG-Installer: floosh.app + Applications-Verknüpfung.
set -e
cd "$(dirname "$0")/.."

./bundle-app.sh

VERSION=$(defaults read "$PWD/build/floosh.app/Contents/Info" CFBundleShortVersionString)
DMG="build/floosh-$VERSION.dmg"

STAGE="$(mktemp -d)/floosh"
mkdir -p "$STAGE"
cp -R build/floosh.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "floosh $VERSION" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO -ov "$DMG" > /dev/null
rm -rf "$STAGE"

echo "✓ Fertig: $DMG"
