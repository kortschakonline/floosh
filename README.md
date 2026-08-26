<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/logo-dark.png">
  <img src="docs/logo-light.png" alt="floosh" height="72">
</picture>

Mini-Menüleisten-App für macOS: zeigt den aktuellen Datendurchsatz von drei Gruppen —
**Intern** (interne Laufwerke), **Extern** (USB/Thunderbolt-Laufwerke) und **Netzwerk**
(physische Interfaces, Down/Up) — plus **System**: CPU- & GPU-Auslastung,
Die-Temperaturen und Lüftersteuerung. Liquid-Glass-Dropdown mit Live-Diagrammen,
Spitzenwerten und Geräteliste. Logo: der floosh-Doppel-Blitz (SVG-Quelle in
`Logo & Icon Source/`, als Vektorpfade eingebettet in `BrandLogos.swift`,
zusammen mit der JRN.digital-Wortmarke aus `jrn Logo Source/`).

- SwiftUI `MenuBarExtra` (Window-Style) · Liquid Glass (`glassEffect`) · Swift Charts
- Messung: IOKit `IOBlockStorageDriver`-Statistiken (Laufwerke, Klassifizierung über
  `Physical Interconnect Location` am Eltern-`IOBlockStorageDevice`) und
  `sysctl NET_RT_IFLIST2` (Netzwerk). Raten aus Zähler-Deltas, kein Root nötig.
- System-Karte: CPU-Auslastung (`host_processor_info`), GPU-Auslastung
  (`IOAccelerator` → `Device Utilization %`), Temperaturen aus dem SMC
  (`Tp*` = CPU, `Tg*` = GPU; pro physischem Sensor nur der Basis-Key der
  Dreiergruppe, die übrigen sind Kalibrier-Offsets), Lüfter über `F#Ac/Mn/Mx/Tg/Md`.
- Lüftersteuerung Auto/Manuell: Schieberegler 0–100 % (zwischen Min- und Max-RPM)
  plus zwei Drehzahl-Favoriten (Rechtsklick auf den Knopf speichert den aktuellen
  Regler-Wert). SMC-Schreiben braucht Root → `FlooshFanHelper` als LaunchDaemon
  im Bundle (`SMAppService.daemon`, einmalige Freigabe unter Anmeldeobjekte,
  App muss dafür in `/Applications` liegen). Sicherheitsnetz: ohne Ping der App
  stellt der Helper nach 3 Minuten selbstständig auf Automatik zurück; auch beim
  Beenden der App wird die Regelung zurückgegeben.
- Menüleisten-Label: nur Symbol / eine Zeile / zwei Zeilen, Symbol-Stil Outline /
  Gefüllt / Farbig (Gruppenfarbe); optional CPU & GPU zweizeilig als Prozentzahl
  oder Mini-Balken. Alles als `NSImage` gerendert — MenuBarExtra
  stellt mehrzeilige SwiftUI-Labels nicht dar und erzwingt sonst Template-Rendering.
- Gruppe wählen: Klick auf eine Karte im Dropdown.
- Einstellungen in eigenem Fenster (⌘, / Zahnrad) mit Tabs **Anzeige · Messung ·
  Lüfter · Allgemein**: Stil, Symbol, Einheit MB/s / Mbit/s, CPU/GPU-Anzeige,
  Intervall 0,5–2 s, Diagramm-Fenster 30–120 s, Quellen-Toggles,
  Lüfter-Favoriten & Helper-Status, Login-Start (`SMAppService`).

## Screenshots

<p>
  <img src="docs/shot-dropdown.png" alt="Liquid-Glass-Dropdown mit System-Karte (CPU/GPU/Temperatur, Lüfter) und Live-Diagrammen" width="360" align="top">
  &nbsp;&nbsp;
  <img src="docs/shot-settings.png" alt="Einstellungen — Anzeige" width="380" align="top">
</p>

## Bauen

```bash
./bundle-app.sh
```

Ergebnis: `build/floosh.app` (Release, ad-hoc-signiert, `LSUIElement`).
Installieren: nach `/Applications` kopieren — oder gleich den Installer bauen:

```bash
./Tools/make-dmg.sh
```

Ergebnis: `build/floosh-<version>.dmg` (App + Applications-Verknüpfung).

Mindestsystem: macOS 14 (Sonoma), Universal Binary (Apple Silicon + Intel).
Liquid Glass gibt es ab macOS 26 — davor rendert dieselbe App eine
Material-Optik (`GlassCompat.swift`). Kein Sandbox-Entitlement nötig.

## Hinweise

- „Netzwerk" misst Interface-Durchsatz (`en*`) — deckt auch Netzlaufwerk-Traffic ab.
  SMB/NFS-Volumes haben keine per-Volume-Zähler ohne Root.
- Interfaces ohne jeglichen bisherigen Traffic (XHC*, tote en*) werden ausgeblendet;
  VPN/virtuelle Interfaces (utun*, awdl* …) optional zuschaltbar.
- SMC-Structs müssen dem 80-Byte-C-Layout des Kernels entsprechen — inklusive
  der 3 Pad-Bytes hinter `SMCKeyInfoData` (sonst sind alle Keys „nicht lesbar").
- Lüfterlose Macs (MacBook Air): `FNum` = 0, die Lüfter-Sektion wird ausgeblendet.
- Die Marken-Logos werden mit fester „Logo-Tinte" gefüllt (weiches Weiß bzw.
  Anthrazit je nach Erscheinungsbild) — `.primary` wird auf Liquid Glass durch
  Vibrancy so stark abgedunkelt, dass die Logos kaum sichtbar waren.
- Disk-Images (`Virtual Interface`) zählen optional zu „Intern" (Standard: aus,
  vermeidet Doppelzählung).
- Synthetische AppleScript-Klicks öffnen MenuBarExtra-Fenster unter macOS 26 nicht —
  für UI-Tests echte CGEvent-HID-Klicks verwenden. Alternativ die Dev-Hooks:
  `floosh --snapshot <ordner>` rendert Dropdown + Label-Varianten offscreen als
  PNG (ohne Glas), `floosh --shoot` zeigt Dropdown/Einstellungen in echten
  Fenstern (echtes Liquid Glass) und meldet Region/Fenster-ID auf stdout für
  ein externes `screencapture` — so entstanden die README-Screenshots
  (`--shoot settings` nur das Einstellungsfenster, ohne Warmlaufphase).
- App-Icon wird per `Tools/make-icon.sh` aus den Marken-Pfaden in
  `BrandLogos.swift` generiert (Navy-Kachel + Doppel-Blitz) und liegt als
  `AppIcon.icns` im Repo.
- `BrandLogos.swift` wurde aus den SVGs konvertiert (SVG-Pfaddaten →
  SwiftUI-`Path`); bei Logo-Änderungen die SVGs austauschen und neu
  konvertieren, nicht die Pfade von Hand editieren.
