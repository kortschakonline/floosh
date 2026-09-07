import Foundation
import Observation

/// Kleiner gemeinsamer Schalter für die Werkzeuge in der System-Karte.
/// Wachhalten und Reinigen haben ihren eigenen Zustand (`KeepAwake`,
/// `CleanScreen`) — hier steht nur, ob die Zeile überhaupt erscheint.
@MainActor
@Observable
final class ToolSettings {

    static let shared = ToolSettings()

    var showTools: Bool {
        didSet { defaults.set(showTools, forKey: "tools.show") }
    }

    private let defaults = UserDefaults.standard

    private init() {
        showTools = defaults.object(forKey: "tools.show") as? Bool ?? true
    }
}
