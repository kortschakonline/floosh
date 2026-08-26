#!/bin/zsh
# Baut floosh.app aus dem SwiftPM-Paket (Release) und signiert ad hoc.
# Enthält den privilegierten Lüfter-Helper als LaunchDaemon im Bundle.
set -e
cd "$(dirname "$0")"

echo "→ Release-Build (Universal: arm64 + x86_64) …"
BIN=".build/apple/Products/Release/Floosh"
HELPER_BIN=".build/apple/Products/Release/FlooshFanHelper"
if ! swift build -c release --arch arm64 --arch x86_64; then
  echo "→ Universal-Build fehlgeschlagen — Fallback: nur arm64 …"
  BIN=".build/release/Floosh"
  HELPER_BIN=".build/release/FlooshFanHelper"
if ! swift build -c release; then
  # Fallback für Macs, auf denen swift build nicht kann (CLT ohne SwiftUI-
  # Makros bzw. Xcode-Lizenz noch nicht akzeptiert): die Xcode-Toolchain
  # DIREKT aufrufen — die /usr/bin-Shims (xcrun) verweigern bei
  # unakzeptierter Xcode-Lizenz jeden Aufruf, die Binaries darunter nicht.
  # Wichtig: swiftc, SDK und SwiftUI-Makro-Plugin müssen aus DEMSELBEN
  # Xcode kommen (CLT-SDK + Xcode-Plugin mischen bricht an der Makro-ABI).
  # Die FlooshShared-Quellen werden dabei einfach mit einkompiliert
  # (die Targets nutzen dafür `#if canImport(FlooshShared)`).
  XC="/Applications/Xcode.app/Contents/Developer"
  PLUGIN="$XC/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
  echo "→ swift build fehlgeschlagen — Fallback: Xcode-swiftc direkt …"
  [[ -f "$PLUGIN" ]] || { echo "✗ $PLUGIN fehlt (Xcode installiert?)"; exit 1 }
  mkdir -p .build/release
  "$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" \
    -O -parse-as-library -target arm64-apple-macos26.0 \
    -sdk "$XC/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" \
    -load-plugin-library "$PLUGIN" \
    Sources/Floosh/*.swift Sources/FlooshShared/*.swift -o "$BIN"
  "$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" \
    -O -target arm64-apple-macos26.0 \
    -sdk "$XC/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" \
    Sources/FlooshFanHelper/*.swift Sources/FlooshShared/*.swift -o "$HELPER_BIN"
fi
fi

APP="build/floosh.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN" "$APP/Contents/MacOS/floosh"
cp "$HELPER_BIN" "$APP/Contents/MacOS/FlooshFanHelper"

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
	<string>1.1.0</string>
	<key>CFBundleVersion</key>
	<string>2</string>
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

# LaunchDaemon-Plist für den Lüfter-Helper (Registrierung via SMAppService,
# Freigabe durch den Nutzer unter Systemeinstellungen → Anmeldeobjekte)
cat > "$APP/Contents/Library/LaunchDaemons/digital.jrn.floosh.fanhelper.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>digital.jrn.floosh.fanhelper</string>
	<key>BundleProgram</key>
	<string>Contents/MacOS/FlooshFanHelper</string>
	<key>MachServices</key>
	<dict>
		<key>digital.jrn.floosh.fanhelper</key>
		<true/>
	</dict>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>digital.jrn.floosh</string>
	</array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/MacOS/FlooshFanHelper"
codesign --force --sign - "$APP"
echo "✓ Fertig: $APP"
echo "  Installieren:  cp -R $APP /Applications/"
echo "  Hinweis: Manuelle Lüftersteuerung setzt voraus, dass die App aus"
echo "  /Applications läuft (LaunchDaemon-Freigabe unter Anmeldeobjekte)."
