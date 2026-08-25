# floosh ⚡

Mini-Menüleisten-App für macOS: zeigt den aktuellen Datendurchsatz von drei Gruppen —
**Intern** (interne Laufwerke), **Extern** (USB/Thunderbolt-Laufwerke) und **Netzwerk**
(physische Interfaces, Down/Up). Liquid-Glass-Dropdown mit Live-Diagrammen,
Spitzenwerten und Geräteliste. Logo: eine Stoppuhr, durch die ein Blitz fährt.

- SwiftUI `MenuBarExtra` (Window-Style) · Liquid Glass (`glassEffect`) · Swift Charts
- Messung: IOKit `IOBlockStorageDriver`-Statistiken (Laufwerke, Klassifizierung über
  `Physical Interconnect Location` am Eltern-`IOBlockStorageDevice`) und
  `sysctl NET_RT_IFLIST2` (Netzwerk). Raten aus Zähler-Deltas, kein Root nötig.
- Menüleisten-Label: nur Symbol / eine Zeile / zwei Zeilen, Symbol-Stil Outline /
  Gefüllt / Farbig (Gruppenfarbe). Alles als `NSImage` gerendert — MenuBarExtra
  stellt mehrzeilige SwiftUI-Labels nicht dar und erzwingt sonst Template-Rendering.
- Gruppe wählen: Klick auf eine Karte im Dropdown.
- Einstellungen in eigenem Fenster (⌘, / Zahnrad) mit Tabs **Anzeige · Messung ·
  Allgemein**: Stil, Symbol, Einheit MB/s / Mbit/s, Intervall 0,5–2 s,
  Diagramm-Fenster 30–120 s, Quellen-Toggles, Login-Start (`SMAppService`).

## Bauen

```bash
./bundle-app.sh
```

Ergebnis: `build/floosh.app` (Release, ad-hoc-signiert, `LSUIElement`).
Installieren: nach `/Applications` kopieren.

Mindestsystem: macOS 26 (Liquid Glass). Kein Sandbox-Entitlement nötig.

## Hinweise

- „Netzwerk" misst Interface-Durchsatz (`en*`) — deckt auch Netzlaufwerk-Traffic ab.
  SMB/NFS-Volumes haben keine per-Volume-Zähler ohne Root.
- Interfaces ohne jeglichen bisherigen Traffic (XHC*, tote en*) werden ausgeblendet;
  VPN/virtuelle Interfaces (utun*, awdl* …) optional zuschaltbar.
- Disk-Images (`Virtual Interface`) zählen optional zu „Intern" (Standard: aus,
  vermeidet Doppelzählung).
- Synthetische AppleScript-Klicks öffnen MenuBarExtra-Fenster unter macOS 26 nicht —
  für UI-Tests echte CGEvent-HID-Klicks verwenden.
- App-Icon wird per Script generiert (Stoppuhr + Blitz, CoreGraphics/SF Symbols) und
  liegt als `AppIcon.icns` im Repo.
