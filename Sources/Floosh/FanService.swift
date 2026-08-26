import Foundation
import ServiceManagement
import Observation
#if canImport(FlooshShared)
import FlooshShared
#endif

/// Steuert den privilegierten Lüfter-Helper (LaunchDaemon) per XPC.
///
/// Ablauf: Der Helper liegt im App-Bundle und wird einmalig über
/// `SMAppService.daemon` registriert — macOS verlangt dafür die Freigabe in
/// Systemeinstellungen → Allgemein → Anmeldeobjekte. Danach kann floosh die
/// Lüfter auf feste Drehzahlen stellen; im Manuell-Modus hält ein
/// periodischer Ping den Helper wach, sonst kehrt er nach 3 Minuten
/// selbstständig zur Automatik zurück.
@MainActor
@Observable
final class FanService {

    static let shared = FanService()

    enum Mode: String {
        case auto, manual
    }

    enum HelperState: Equatable {
        case unavailable(String)   // z. B. nicht registrierbar (nicht in /Applications)
        case needsRegistration
        case needsApproval
        case ready
    }

    var mode: Mode = .auto
    /// Manuelle Drehzahl in Prozent (0 = Min-RPM, 100 = Max-RPM).
    var percent: Double
    var favorite1: Double { didSet { defaults.set(favorite1, forKey: "ds.fanFav1") } }
    var favorite2: Double { didSet { defaults.set(favorite2, forKey: "ds.fanFav2") } }
    private(set) var helperState: HelperState = .needsRegistration
    private(set) var lastError: String?

    private let defaults = UserDefaults.standard
    private var connection: NSXPCConnection?
    private var pingTask: Task<Void, Never>?
    private var service: SMAppService { SMAppService.daemon(plistName: fanHelperPlistName) }

    init() {
        percent = defaults.object(forKey: "ds.fanPercent") as? Double ?? 50
        favorite1 = defaults.object(forKey: "ds.fanFav1") as? Double ?? 40
        favorite2 = defaults.object(forKey: "ds.fanFav2") as? Double ?? 80
        refreshHelperState()
    }

    // MARK: Helper-Registrierung

    func refreshHelperState() {
        switch service.status {
        case .enabled: helperState = .ready
        case .requiresApproval: helperState = .needsApproval
        case .notRegistered, .notFound: helperState = .needsRegistration
        @unknown default: helperState = .needsRegistration
        }
    }

    /// Registriert den Daemon; führt je nach Systemzustand zur Freigabe-Abfrage.
    func registerHelper() {
        lastError = nil
        do {
            try service.register()
            refreshHelperState()
        } catch {
            refreshHelperState()
            if helperState == .needsApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else {
                let hint = Bundle.main.bundlePath.hasPrefix("/Applications")
                    ? ""
                    : " — floosh muss dafür in /Applications liegen"
                helperState = .unavailable("Registrierung fehlgeschlagen: \(error.localizedDescription)\(hint)")
            }
        }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: XPC

    private func proxy() -> FlooshFanHelperProtocol? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: fanHelperMachName, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: FlooshFanHelperProtocol.self)
            c.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in
                self?.lastError = "Helper nicht erreichbar: \(error.localizedDescription)"
                self?.connection?.invalidate()
                self?.connection = nil
            }
        } as? FlooshFanHelperProtocol
    }

    // MARK: Steuerung

    func setAuto() {
        mode = .auto
        stopPinging()
        lastError = nil
        guard helperState == .ready else { return }
        proxy()?.setAuto { [weak self] error in
            Task { @MainActor in self?.lastError = error }
        }
    }

    func setManual(percent newPercent: Double? = nil) {
        if let newPercent { percent = min(max(newPercent, 0), 100) }
        defaults.set(percent, forKey: "ds.fanPercent")
        mode = .manual
        guard helperState == .ready else { return }
        lastError = nil
        proxy()?.setManual(percent: percent) { [weak self] error in
            Task { @MainActor in
                self?.lastError = error
                if error == nil { self?.startPinging() }
            }
        }
    }

    /// Beim Beenden der App die Regelung zurückgeben (Best Effort; falls die
    /// App abstürzt, greift der Ping-Watchdog des Helpers).
    func relinquishOnQuit() {
        guard mode == .manual, helperState == .ready else { return }
        proxy()?.setAuto { _ in }
        // Dem XPC-Call einen Moment Zeit geben, bevor der Prozess endet.
        Thread.sleep(forTimeInterval: 0.15)
    }

    private func startPinging() {
        guard pingTask == nil else { return }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.mode == .manual else { return }
                self.proxy()?.ping()
            }
        }
    }

    private func stopPinging() {
        pingTask?.cancel()
        pingTask = nil
    }
}
