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

# Signieren und von Apple beglaubigen lassen, wenn eine Developer ID
# vorliegt. Beglaubigung braucht zusätzlich NOTARY_APPLE_ID,
# NOTARY_PASSWORD (App-spezifisches Passwort) und NOTARY_TEAM_ID.
if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  if [[ -n "$NOTARY_APPLE_ID" && -n "$NOTARY_PASSWORD" && -n "$NOTARY_TEAM_ID" ]]; then
    echo "→ Beglaubigung bei Apple (dauert meist 1–5 Minuten) …"
    RESULT=$(xcrun notarytool submit "$DMG" --apple-id "$NOTARY_APPLE_ID" \
      --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID" \
      --wait --output-format json)
    STATUS=$(print -r -- "$RESULT" | plutil -extract status raw -o - -)
    if [[ "$STATUS" != "Accepted" ]]; then
      echo "✗ Beglaubigung: $STATUS"
      ID=$(print -r -- "$RESULT" | plutil -extract id raw -o - -)
      xcrun notarytool log "$ID" --apple-id "$NOTARY_APPLE_ID" \
        --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID" || true
      exit 1
    fi
    xcrun stapler staple "$DMG"
    echo "✓ Beglaubigt"
  else
    echo "→ Keine Zugangsdaten für die Beglaubigung — nur signiert"
  fi
fi

echo "✓ Fertig: $DMG"
