import Foundation
import IOKit.pwr_mgt
import Observation

/// Hält den Bildschirm wach, solange es eingeschaltet ist — dieselbe
/// Mechanik wie `caffeinate`, nur ohne Prozess: eine Energie-Zusicherung
/// beim System (`IOPMAssertion`). Kein Root, keine Freigabe nötig.
///
/// Bewusst nicht über Neustarts hinweg gespeichert: Ein Bildschirm, der ohne
/// erkennbaren Grund nie mehr schlafen geht, ist ein Fehler, kein Feature.
@MainActor
@Observable
final class KeepAwake {

    static let shared = KeepAwake()

    /// Wie lange wachgehalten wird.
    enum Duration: String, CaseIterable, Identifiable {
        case indefinite, min30, hour1, hour2

        var id: String { rawValue }

        var title: String {
            switch self {
            case .indefinite: "Ohne Ende"
            case .min30: "30 min"
            case .hour1: "1 h"
            case .hour2: "2 h"
            }
        }

        /// Sekunden bis zum automatischen Ende; `nil` = kein Ende.
        var seconds: TimeInterval? {
            switch self {
            case .indefinite: nil
            case .min30: 30 * 60
            case .hour1: 60 * 60
            case .hour2: 2 * 60 * 60
            }
        }
    }

    private(set) var isActive = false
    /// Zeitpunkt, an dem sich das Wachhalten selbst beendet (bei „Ohne Ende" nil).
    private(set) var endsAt: Date?

    var duration: Duration {
        didSet { defaults.set(duration.rawValue, forKey: "awake.duration") }
    }

    private var assertion: IOPMAssertionID = 0
    private var countdown: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    private init() {
        duration = Duration(rawValue: defaults.string(forKey: "awake.duration") ?? "") ?? .indefinite
    }

    /// Verbleibende Zeit als „1:23" bzw. „12 min" — nur zur Anzeige.
    var remainingText: String? {
        guard let endsAt else { return nil }
        let left = max(0, endsAt.timeIntervalSinceNow)
        let minutes = Int(left / 60)
        if minutes >= 60 {
            return String(format: "%d:%02d", minutes / 60, minutes % 60)
        }
        return "\(minutes + 1) min"
    }

    func toggle() {
        isActive ? stop() : start()
    }

    func start() {
        guard !isActive else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "floosh hält den Bildschirm wach" as CFString,
            &id)
        guard result == kIOReturnSuccess else { return }

        assertion = id
        isActive = true

        if let seconds = duration.seconds {
            let end = Date().addingTimeInterval(seconds)
            endsAt = end
            countdown = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } else {
            endsAt = nil
        }
    }

    func stop() {
        countdown?.cancel()
        countdown = nil
        endsAt = nil
        guard isActive else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
        isActive = false
    }
}
