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
/// Lüfter auf feste Drehzahlen stellen; in den Modi Manuell und Kurve hält
/// ein periodischer Ping den Helper wach, sonst kehrt er nach 3 Minuten
/// selbstständig zur Automatik zurück.
///
/// Kurven-Modus: Die App wertet die Lüfterkurve bei jeder Messrunde des
/// StatsEngine aus (`curveTick`) und schickt dem Helper nur dann eine neue
/// Drehzahl, wenn sich der gerundete Zielwert ändert. Der Helper selbst kennt
/// keine Kurve — er bleibt die minimale Root-Komponente.
@MainActor
@Observable
final class FanService {

    static let shared = FanService()

    enum Mode: String {
        case auto, manual, curve
    }

    enum HelperState: Equatable {
        case unavailable(String)   // z. B. nicht registrierbar (nicht in /Applications)
        case needsRegistration
        case needsApproval
        /// Registriert, aber die Registrierung gehört zu einer älteren
        /// Ausgabe der App — der Helper startet nicht (siehe `syncRegistration`).
        case staleRegistration
        case ready
    }

    var mode: Mode = .auto
    /// Manuelle Drehzahl in Prozent (0 = Min-RPM, 100 = Max-RPM).
    var percent: Double
    var favorite1: Double { didSet { defaults.set(favorite1, forKey: "ds.fanFav1") } }
    var favorite2: Double { didSet { defaults.set(favorite2, forKey: "ds.fanFav2") } }
    /// Temperaturkurve; Änderungen wirken im Kurven-Modus sofort.
    var curve: FanCurve {
        didSet {
            if let data = try? JSONEncoder().encode(curve) {
                defaults.set(data, forKey: "ds.fanCurve")
            }
            applyCurve(force: false)
        }
    }
    /// Geglättete Sensortemperatur, die die Kurve gerade sieht.
    private(set) var curveTemp: Double?
    /// Aus der Kurve berechnete Zieldrehzahl in Prozent (auch außerhalb des
    /// Kurven-Modus, als Vorschau).
    private(set) var curveTarget: Double?
    private(set) var helperState: HelperState = .needsRegistration
    private(set) var lastError: String?

    private let defaults = UserDefaults.standard
    private var connection: NSXPCConnection?
    private var pingTask: Task<Void, Never>?
    private var lastSentPercent: Double?
    private var lastCurveTick: Date?
    private var service: SMAppService { SMAppService.daemon(plistName: fanHelperPlistName) }

    init() {
        percent = defaults.object(forKey: "ds.fanPercent") as? Double ?? 50
        favorite1 = defaults.object(forKey: "ds.fanFav1") as? Double ?? 40
        favorite2 = defaults.object(forKey: "ds.fanFav2") as? Double ?? 80
        curve = defaults.data(forKey: "ds.fanCurve")
            .flatMap { try? JSONDecoder().decode(FanCurve.self, from: $0) } ?? .standard
        // Nur der Kurven-Modus überlebt einen Neustart — eine feste manuelle
        // Drehzahl soll nicht unbemerkt weiterlaufen.
        if defaults.string(forKey: "ds.fanMode") == Mode.curve.rawValue {
            mode = .curve
        }
        refreshHelperState()
        verifyHelperReachable()
    }

    /// Prüft beim Start, ob der registrierte Helper wirklich antwortet.
    ///
    /// Nötig, weil `service.status` lügt: `SMAppService.register()` hinterlegt
    /// beim Daemon eine Startbedingung auf den *cdhash* der Helper-Binary.
    /// Passt die nicht mehr — etwa weil die Registrierung von einer viel
    /// älteren Ausgabe stammt —, lehnt launchd den Start mit `EX_CONFIG` ab,
    /// während der Status weiterhin `.enabled` meldet. Erst der XPC-Kontakt
    /// bringt es an den Tag; der Fehlerpfad in `proxy()` setzt dann
    /// `staleRegistration`.
    ///
    /// Bewusst kein Vergleich von Build-Nummern: Der cdhash der Helper-Binary
    /// ändert sich nicht bei jedem Release, ein Update allein ist also kein
    /// Grund, dem Benutzer eine Neuregistrierung samt Freigabe zuzumuten.
    private func verifyHelperReachable() {
        guard case .ready = helperState else { return }
        proxy()?.version { _ in }
    }

    /// Registrierung erneuern: abmelden, warten, neu anmelden.
    ///
    /// `register()` allein genügt nicht — auf einen bereits registrierten
    /// Dienst wirkt es nicht, die alte Startbedingung bliebe stehen. Und das
    /// Anmelden darf dem Abmelden nicht auf dem Fuß folgen: Solange das
    /// System den alten Eintrag noch abräumt, scheitert es mit „Operation not
    /// permitted" — und dann wäre gar nichts mehr registriert. Deshalb mit
    /// Pause und mehreren Anläufen.
    func reregisterHelper() {
        guard !isReregistering else { return }
        isReregistering = true
        lastError = nil
        Task { @MainActor in
            defer { isReregistering = false }
            try? await service.unregister()
            var lastFailure: Error?
            for attempt in 0..<3 {
                try? await Task.sleep(for: .milliseconds(attempt == 0 ? 700 : 1800))
                do {
                    try service.register()
                    connection?.invalidate()
                    connection = nil
                    refreshHelperState()
                    return
                } catch {
                    lastFailure = error
                }
            }
            refreshHelperState()
            if helperState == .needsApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else if let lastFailure {
                helperState = .unavailable("Neuregistrierung fehlgeschlagen: \(lastFailure.localizedDescription)")
            }
        }
    }

    /// Läuft gerade eine Neuregistrierung? (Doppelklicks abfangen.)
    private(set) var isReregistering = false

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
                guard let self else { return }
                self.lastError = "Helper nicht erreichbar: \(error.localizedDescription)"
                self.connection?.invalidate()
                self.connection = nil
                // Meldet das System den Dienst als aktiv, obwohl niemand
                // antwortet, passt fast immer die Registrierung nicht mehr
                // zur Binary.
                if case .ready = self.helperState {
                    self.helperState = .staleRegistration
                }
            }
        } as? FlooshFanHelperProtocol
    }

    /// Nur für `--helper-ping`: fragt die Protokoll-Version des laufenden
    /// Helpers ab. Kommt eine Antwort, steht die privilegierte Verbindung.
    func pingHelperForDiagnostics(_ done: @escaping @Sendable (String) -> Void) {
        guard let proxy = proxy() else {
            done("Antwort: keine Verbindung möglich")
            return
        }
        proxy.version { version in
            done("Antwort: Helper läuft, Protokoll-Version \(version) (erwartet \(fanHelperVersion))")
        }
    }

    // MARK: Steuerung

    func setAuto() {
        mode = .auto
        persistMode()
        lastSentPercent = nil
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
        persistMode()
        guard helperState == .ready else { return }
        lastError = nil
        sendManual(percent)
    }

    func setCurve() {
        mode = .curve
        persistMode()
        lastSentPercent = nil
        lastError = nil
        applyCurve(force: true)
    }

    /// Wird vom StatsEngine nach jeder Abtastung mit den aktuellen
    /// Die-Temperaturen aufgerufen.
    func curveTick(cpuTemp: Double?, gpuTemp: Double?) {
        let now = Date()
        defer { lastCurveTick = now }
        guard let raw = curve.temperature(cpu: cpuTemp, gpu: gpuTemp) else {
            curveTemp = nil
            curveTarget = nil
            return
        }
        // Asymmetrische Glättung: schnell hochregeln, langsam zurück —
        // kein Flattern bei kurzen Lastspitzen, kein Nachlaufen beim Aufheizen.
        if let prev = curveTemp, let last = lastCurveTick {
            let dt = max(0, now.timeIntervalSince(last))
            let tau: Double = raw > prev ? 3 : 20
            curveTemp = prev + (1 - exp(-dt / tau)) * (raw - prev)
        } else {
            curveTemp = raw
        }
        applyCurve(force: false)
    }

    /// Zielwert aus der Kurve neu berechnen und — im Kurven-Modus — an den
    /// Helper schicken, falls er sich geändert hat.
    private func applyCurve(force: Bool) {
        guard let temp = curveTemp else {
            curveTarget = nil
            return
        }
        let target = curve.percent(at: temp).rounded()
        curveTarget = target
        guard mode == .curve, helperState == .ready else { return }
        guard force || target != lastSentPercent else { return }
        sendManual(target)
    }

    private func sendManual(_ value: Double) {
        // Optimistisch merken, damit dicht folgende Ticks nicht doppelt senden;
        // bei Fehler zurücksetzen, damit der nächste Tick es erneut versucht.
        lastSentPercent = value
        proxy()?.setManual(percent: value) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.lastError = error
                if error == nil {
                    self.startPinging()
                } else {
                    self.lastSentPercent = nil
                }
            }
        }
    }

    private func persistMode() {
        defaults.set(mode == .curve ? Mode.curve.rawValue : Mode.auto.rawValue, forKey: "ds.fanMode")
    }

    /// Beim Beenden der App die Regelung zurückgeben (Best Effort; falls die
    /// App abstürzt, greift der Ping-Watchdog des Helpers).
    func relinquishOnQuit() {
        guard mode != .auto, helperState == .ready else { return }
        proxy()?.setAuto { _ in }
        // Dem XPC-Call einen Moment Zeit geben, bevor der Prozess endet.
        Thread.sleep(forTimeInterval: 0.15)
    }

    private func startPinging() {
        guard pingTask == nil else { return }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.mode != .auto else { return }
                self.proxy()?.ping()
            }
        }
    }

    private func stopPinging() {
        pingTask?.cancel()
        pingTask = nil
    }
}
