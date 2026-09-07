import SwiftUI
import Observation

/// Zentraler Feature-Katalog. Heute ist alles frei — eine spätere Pro-Variante
/// ändert nur `tier` und den Lizenz-Status in `Entitlements`; die Views fragen
/// ausschließlich `Entitlements.isUnlocked(_:)` bzw. `featureGated(_:)`.
enum Feature: String, CaseIterable, Identifiable {
    // Dropdown
    case cardSize, gridLayout, selectionStyle
    // Lüfter
    case fanManual, fanCurve
    // Menüleiste
    case menuChannel, menuThermal, menuSparkline, menuHideIdle, menuTintText
    // Desktop-Panel
    case desktopPanel
    // Ablage
    case fileShelf, dragCatcher
    // Werkzeuge
    case keepAwake, cleanScreen, shortcuts
    // Allgemein
    case updateCheck

    var id: String { rawValue }

    enum Tier { case free, pro }

    var tier: Tier { .free }
}

@MainActor
@Observable
final class Entitlements {
    static let shared = Entitlements()

    /// Platzhalter für den späteren Lizenz-Status (Pro freigeschaltet).
    private(set) var hasPro = false

    func isUnlocked(_ feature: Feature) -> Bool {
        feature.tier == .free || hasPro
    }
}

extension View {
    /// Markiert einen Einstellungs-Einstieg als Feature: gesperrte Features
    /// sind deaktiviert (später ergänzt um Pro-Hinweis/Badge).
    func featureGated(_ feature: Feature) -> some View {
        disabled(!Entitlements.shared.isUnlocked(feature))
    }
}
