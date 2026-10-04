import SwiftUI
import AppKit
import Observation

// MARK: - Bereiche mit eigener Farbe und eigenem Icon

/// Eine Kachel-Familie mit eigener Farbe (und eigenem Icon). Laufwerke
/// teilen sich bewusst eine Farbfamilie (Blautöne), sind aber getrennt
/// einstellbar.
enum ThemeSlot: String, CaseIterable, Identifiable {
    case system, internalDrives, externalDrives, network, shelf, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .internalDrives: "Intern"
        case .externalDrives: "Extern"
        case .network: "Netzwerk"
        case .shelf: "Ablage"
        case .shortcuts: "Kurzbefehle"
        }
    }

    /// Werkseinstellung: System türkis, Laufwerke blau, Netzwerk orange,
    /// Ablage gelb. (Der Akku färbt sich nach Zustand und hat keine feste Farbe.)
    var defaultHex: String {
        switch self {
        case .system: "#2DD4BF"          // Türkis
        case .internalDrives: "#4F8CFF"  // Blau
        case .externalDrives: "#38BDF8"  // Himmelblau
        case .network: "#FB923C"         // Orange
        case .shelf: "#FACC15"           // Gelb
        case .shortcuts: "#F472B6"       // Rosa
        }
    }

    var defaultGlyph: CardGlyph { glyphOptions[0] }

    /// Auswahl in den Einstellungen; das erste Icon ist die Werkseinstellung.
    var glyphOptions: [CardGlyph] {
        switch self {
        case .system:
            [.floosh, .streamline(.computerChip1), .streamline(.computerChip2),
             .sf("cpu"), .sf("memorychip"), .sf("gauge.with.dots.needle.67percent")]
        case .internalDrives:
            [.streamline(.hardDrive1), .streamline(.hardDisk), .sf("internaldrive"), .sf("internaldrive.fill")]
        case .externalDrives:
            [.streamline(.usbDrive), .streamline(.hardDisk), .sf("externaldrive"), .sf("externaldrive.fill")]
        case .network:
            [.streamline(.wifiAntenna), .streamline(.web), .streamline(.network),
             .sf("network"), .sf("wifi"), .sf("globe.europe.africa")]
        case .shelf:
            [.streamline(.inboxTray1), .streamline(.inboxTray2), .sf("tray"), .sf("tray.full")]
        case .shortcuts:
            [.sf("square.stack.3d.up"), .sf("command"), .sf("bolt")]
        }
    }
}

extension SpeedGroup {
    var slot: ThemeSlot {
        switch self {
        case .internalDrives: .internalDrives
        case .externalDrives: .externalDrives
        case .network: .network
        }
    }
}

// MARK: - Icon

/// Ein Kachel-Icon: das floosh-Logo, ein SF Symbol oder ein Streamline-Icon.
enum CardGlyph: Hashable, Identifiable {
    case floosh
    case sf(String)
    case streamline(StreamlineIcon)

    /// Kennung für die Einstellungen.
    var id: String {
        switch self {
        case .floosh: "floosh"
        case .sf(let name): "sf:\(name)"
        case .streamline(let icon): "sl:\(icon.rawValue)"
        }
    }

    init?(id: String) {
        if id == "floosh" { self = .floosh; return }
        if id.hasPrefix("sf:") { self = .sf(String(id.dropFirst(3))); return }
        if id.hasPrefix("sl:"), let icon = StreamlineIcon(rawValue: String(id.dropFirst(3))) {
            self = .streamline(icon); return
        }
        return nil
    }

    var isStreamline: Bool {
        if case .streamline = self { return true }
        return false
    }
}

/// Zeichnet ein `CardGlyph` in der Kachelfarbe.
struct CardGlyphView: View {
    let glyph: CardGlyph
    let tint: Color
    var size: CGFloat

    var body: some View {
        switch glyph {
        case .floosh:
            // Das Markenlogo behält sein Orange, die andere Hälfte nimmt die Kachelfarbe
            ZStack {
                FlooshBoltShape(part: .frame).fill(tint)
                FlooshBoltShape(part: .accent).fill(Color.flooshOrange)
            }
            .frame(width: size * 1.45, height: size * 1.45)
        case .sf(let name):
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
        case .streamline(let icon):
            StreamlineIconShape(icon: icon)
                .fill(tint, style: FillStyle(eoFill: true))
                .frame(width: size * 1.1, height: size * 1.1)
        }
    }
}

// MARK: - Schema

/// Farben und Icons der Kacheln — einstellbar unter Einstellungen → Anzeige.
@MainActor
@Observable
final class CardTheme {
    static let shared = CardTheme()

    private(set) var colors: [ThemeSlot: Color] = [:]
    private(set) var glyphs: [ThemeSlot: CardGlyph] = [:]

    private let defaults = UserDefaults.standard

    private init() {
        for slot in ThemeSlot.allCases {
            colors[slot] = Color(hex: defaults.string(forKey: "theme.color.\(slot.rawValue)") ?? slot.defaultHex)
                ?? Color(hex: slot.defaultHex)!
            glyphs[slot] = defaults.string(forKey: "theme.icon.\(slot.rawValue)").flatMap(CardGlyph.init(id:))
                ?? slot.defaultGlyph
        }
    }

    /// Grundfarbe (z. B. Lesen, CPU).
    func color(_ slot: ThemeSlot) -> Color {
        colors[slot] ?? Color(hex: slot.defaultHex)!
    }

    /// Abgestufte Zweitfarbe (z. B. Schreiben, GPU): heller aus derselben
    /// Familie statt nur durchsichtiger — bleibt auf Glas gut lesbar.
    func secondary(_ slot: ThemeSlot) -> Color {
        color(slot).blended(with: .white, fraction: 0.42)
    }

    func glyph(_ slot: ThemeSlot) -> CardGlyph {
        glyphs[slot] ?? slot.defaultGlyph
    }

    func setColor(_ color: Color, for slot: ThemeSlot) {
        colors[slot] = color
        defaults.set(color.hexString, forKey: "theme.color.\(slot.rawValue)")
    }

    func setGlyph(_ glyph: CardGlyph, for slot: ThemeSlot) {
        glyphs[slot] = glyph
        defaults.set(glyph.id, forKey: "theme.icon.\(slot.rawValue)")
    }

    func reset(_ slot: ThemeSlot) {
        defaults.removeObject(forKey: "theme.color.\(slot.rawValue)")
        defaults.removeObject(forKey: "theme.icon.\(slot.rawValue)")
        colors[slot] = Color(hex: slot.defaultHex)
        glyphs[slot] = slot.defaultGlyph
    }

    func resetAll() {
        ThemeSlot.allCases.forEach(reset)
    }

    func colorBinding(_ slot: ThemeSlot) -> Binding<Color> {
        Binding(get: { self.color(slot) }, set: { self.setColor($0, for: slot) })
    }

    var usesStreamline: Bool {
        glyphs.values.contains(where: \.isStreamline)
    }
}

// MARK: - Farbhilfen

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    /// Mischt die Farbe mit einer anderen (läuft ab macOS 14, anders als `mix`).
    func blended(with other: Color, fraction: CGFloat) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .white
        return Color(nsColor: a.blended(withFraction: fraction, of: b) ?? a)
    }
}
