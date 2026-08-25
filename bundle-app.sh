#!/bin/zsh
# Baut floosh.app aus dem SwiftPM-Paket (Release) und signiert ad hoc.
set -e
cd "$(dirname "$0")"

echo "→ Release-Build …"
swift build -c release

APP="build/floosh.app"
BIN=".build/release/Floosh"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/floosh"

if [[ -f "AppIcon.icns" ]]; then
  cp AppIcon.icns "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>floosh</string>
	<key>CFBundleDisplayName</key>
	<string>floosh</string>
	<key>CFBundleIdentifier</key>
	<string>digital.jrn.floosh</string>
	<key>CFBundleExecutable</key>
	<string>floosh</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>© 2026 JRN.digital</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "✓ Fertig: $APP"
echo "  Installieren:  cp -R $APP /Applications/"
