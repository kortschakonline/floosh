#!/bin/zsh
# Baut AppIcon.icns aus den Marken-Pfaden (Tools/make-icon.swift + BrandLogos.swift).
set -e
cd "$(dirname "$0")/.."

BIN="$(mktemp -d)/make-icon"
ICONSET="build/AppIcon.iconset"

echo "→ Icon-Generator kompilieren …"
swiftc -O -parse-as-library \
  Tools/make-icon.swift Sources/Floosh/BrandLogos.swift \
  -o "$BIN"

echo "→ Iconset rendern …"
rm -rf "$ICONSET"
"$BIN" "$ICONSET"

echo "→ icns bauen …"
iconutil -c icns "$ICONSET" -o AppIcon.icns
rm -rf "$ICONSET"
echo "✓ Fertig: AppIcon.icns"
