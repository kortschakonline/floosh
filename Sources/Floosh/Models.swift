import SwiftUI

// MARK: - Gruppen

enum SpeedGroup: String, CaseIterable, Identifiable, Codable {
    case internalDrives = "intern"
    case externalDrives = "extern"
    case network = "netzwerk"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .internalDrives: "Intern"
        case .externalDrives: "Extern"
        case .network: "Netzwerk"
        }
    }

    var symbol: String {
        switch self {
        case .internalDrives: "internaldrive"
        case .externalDrives: "externaldrive"
        case .network: "network"
        }
    }

    /// Gefüllte Symbol-Variante („network" hat keine — Weltkugel als Entsprechung).
    var filledSymbol: String {
        switch self {
        case .internalDrives: "internaldrive.fill"
        case .externalDrives: "externaldrive.fill"
        case .network: "globe.americas.fill"
        }
    }

    func symbol(for style: MenuIconStyle) -> String {
        style == .filled ? filledSymbol : symbol
    }

    var tint: Color {
        switch self {
        case .internalDrives: Color(red: 0.35, green: 0.55, blue: 1.0)   // Blau
        case .externalDrives: Color(red: 1.0, green: 0.62, blue: 0.25)   // Orange
        case .network: Color(red: 0.30, green: 0.85, blue: 0.55)         // Grün
        }
    }

    /// Kanal-Beschriftungen: Laufwerke lesen/schreiben, Netzwerk lädt herunter/hoch.
    var readLabel: String { self == .network ? "Download" : "Lesen" }
    var writeLabel: String { self == .network ? "Upload" : "Schreiben" }
    var readGlyph: String { self == .network ? "↓" : "L" }
    var writeGlyph: String { self == .network ? "↑" : "S" }

    var deviceNoun: String { self == .network ? "Interface" : "Laufwerk" }
    var deviceNounPlural: String { self == .network ? "Interfaces" : "Laufwerke" }
}

// MARK: - Messwerte

struct Sample {
    let date: Date
    let read: Double   // Bytes/s
    let write: Double  // Bytes/s
}

struct DeviceSpeed: Identifiable {
    let id: String
    let name: String
    let read: Double
    let write: Double
}

// MARK: - Einstellungen

enum SpeedUnits: String, CaseIterable, Identifiable {
    case bytes, bits
    var id: String { rawValue }
    var title: String { self == .bytes ? "MB/s" : "Mbit/s" }
}

enum MenuLabelStyle: String, CaseIterable, Identifiable {
    case symbolOnly, single, split
    var id: String { rawValue }
    var title: String {
        switch self {
        case .symbolOnly: "Nur Symbol"
        case .single: "Eine Zeile"
        case .split: "Zwei Zeilen"
        }
    }
}

/// Welche Richtung die Menüleiste zeigt. Bei „nur Lesen/Schreiben" wird
/// auch der zweizeilige Stil einzeilig.
enum MenuChannel: String, CaseIterable, Identifiable {
    case both, read, write
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: "Beide"
        case .read: "Lesen · ↓"
        case .write: "Schreiben · ↑"
        }
    }
}

/// Temperatur-/Lüfter-Block in der Menüleiste (zweizeilig).
enum MenuThermalStyle: String, CaseIterable, Identifiable {
    case off, temp, fan, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Aus"
        case .temp: "Temperatur"
        case .fan: "Lüfter"
        case .both: "Beides"
        }
    }
}

/// Anordnung der Karten im Dropdown.
enum DropdownLayout: String, CaseIterable, Identifiable {
    case list, grid
    var id: String { rawValue }
    var title: String { self == .list ? "Liste" : "Raster" }
}

/// Darstellung von CPU- & GPU-Auslastung in der Menüleiste (zweizeilig).
enum MenuSystemStyle: String, CaseIterable, Identifiable {
    case off, number, bar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Aus"
        case .number: "Zahl (%)"
        case .bar: "Balken"
        }
    }
}

/// Größe der Karten im Dropdown — skaliert Breite, Abstände, Symbole,
/// Schriften und Diagrammhöhe gemeinsam.
enum CardSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var title: String {
        switch self {
        case .small: "Klein"
        case .medium: "Mittel"
        case .large: "Groß"
        }
    }

    var dropdownWidth: CGFloat {
        switch self {
        case .small: 300
        case .medium: 340
        case .large: 400
        }
    }
    /// Breite im Raster-Layout: zwei Karten in Listenbreite nebeneinander.
    var gridWidth: CGFloat {
        2 * dropdownWidth - 2 * outerPadding + outerSpacing
    }
    /// Abstand zwischen den Karten und Rand des Dropdowns.
    var outerSpacing: CGFloat {
        switch self {
        case .small: 9
        case .medium: 12
        case .large: 14
        }
    }
    var outerPadding: CGFloat {
        switch self {
        case .small: 11
        case .medium: 14
        case .large: 16
        }
    }
    var padding: CGFloat {
        switch self {
        case .small: 9
        case .medium: 12
        case .large: 15
        }
    }
    /// Abstand zwischen Kopfzeile, Diagramm und Details innerhalb der Karte.
    var spacing: CGFloat {
        switch self {
        case .small: 7
        case .medium: 10
        case .large: 12
        }
    }
    var cornerRadius: CGFloat {
        switch self {
        case .small: 16
        case .medium: 20
        case .large: 24
        }
    }
    /// Durchmesser des Symbol-Kreises in der Kopfzeile.
    var iconSize: CGFloat {
        switch self {
        case .small: 28
        case .medium: 34
        case .large: 42
        }
    }
    var iconFont: CGFloat {
        switch self {
        case .small: 13
        case .medium: 16
        case .large: 19
        }
    }
    var titleFont: Font {
        switch self {
        case .small: .system(.callout, design: .rounded, weight: .semibold)
        case .medium: .system(.body, design: .rounded, weight: .semibold)
        case .large: .system(.title3, design: .rounded, weight: .semibold)
        }
    }
    /// Große Live-Werte (Rate bzw. Temperatur).
    var valueFont: CGFloat {
        switch self {
        case .small: 13
        case .medium: 15
        case .large: 18
        }
    }
    var glyphFont: CGFloat {
        switch self {
        case .small: 10
        case .medium: 11
        case .large: 13
        }
    }
    var chartHeight: CGFloat {
        switch self {
        case .small: 32
        case .medium: 46
        case .large: 64
        }
    }
}

/// Wie die in der Menüleiste gezeigte (aktive) Karte hervorgehoben wird.
enum SelectionStyle: String, CaseIterable, Identifiable {
    case border, subtle, strong
    var id: String { rawValue }
    var title: String {
        switch self {
        case .border: "Rahmen"
        case .subtle: "Dezent"
        case .strong: "Kräftig"
        }
    }
}

/// Stil des Symbols in der Menüleiste.
enum MenuIconStyle: String, CaseIterable, Identifiable {
    case outline, filled, color
    var id: String { rawValue }
    var title: String {
        switch self {
        case .outline: "Outline"
        case .filled: "Gefüllt"
        case .color: "Farbig"
        }
    }
}

// MARK: - Formatierung

enum SpeedFormat {
    private static let formatters: [Int: NumberFormatter] = {
        var dict: [Int: NumberFormatter] = [:]
        for decimals in 0...1 {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.minimumFractionDigits = decimals
            f.maximumFractionDigits = decimals
            f.locale = .current
            dict[decimals] = f
        }
        return dict
    }()

    private static func number(_ value: Double, decimals: Int) -> String {
        formatters[decimals]?.string(from: NSNumber(value: value)) ?? String(format: "%.\(decimals)f", value)
    }

    /// Formatiert Bytes/s als lesbare Rate. `compact` liefert die Kurzform für die Menüleiste.
    static func speed(_ bytesPerSec: Double, units: SpeedUnits, compact: Bool = false) -> String {
        let value = units == .bits ? bytesPerSec * 8 : bytesPerSec
        let (scaled, unit): (Double, String)
        switch value {
        case ..<1_000:
            (scaled, unit) = (value, units == .bits ? "bit" : "B")
        case ..<1_000_000:
            (scaled, unit) = (value / 1_000, units == .bits ? "kbit" : "KB")
        case ..<1_000_000_000:
            (scaled, unit) = (value / 1_000_000, units == .bits ? "Mbit" : "MB")
        default:
            (scaled, unit) = (value / 1_000_000_000, units == .bits ? "Gbit" : "GB")
        }
        let decimals = scaled >= 100 ? 0 : 1
        let num = number(scaled, decimals: decimals)
        if compact {
            // Kurzform: "12,4M" — Einheit auf einen Buchstaben reduziert
            let short: String
            switch unit {
            case "B", "bit": short = units == .bits ? "b" : "B"
            case "KB", "kbit": short = units == .bits ? "k" : "K"
            case "MB", "Mbit": short = "M"
            default: short = "G"
            }
            return "\(num)\(short)"
        }
        return "\(num) \(unit)/s"
    }
}
