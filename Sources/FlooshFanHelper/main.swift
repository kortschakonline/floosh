import Foundation
#if canImport(FlooshShared)
import FlooshShared
#endif

/// Privilegierter Lüfter-Helper von floosh.
///
/// Läuft als LaunchDaemon (Root), lauscht auf dem Mach-Service
/// `digital.jrn.floosh.fanhelper` und führt ausschließlich die zwei
/// SMC-Schreiboperationen aus, die die App nicht selbst darf:
/// Lüfter auf feste Drehzahl stellen und zurück auf Automatik.
///
/// Sicherheitsnetz: Ohne `ping()` der App fällt der Manuell-Modus nach
/// `pingTimeout` automatisch auf die Systemregelung zurück — ein Absturz
/// der App kann die Lüfter also nie dauerhaft festnageln.
final class FanHelper: NSObject, NSXPCListenerDelegate, FlooshFanHelperProtocol {

    private let queue = DispatchQueue(label: "digital.jrn.floosh.fanhelper.smc")
    private var smc: SMCConnection?
    private var manualActive = false
    private var lastPing = Date()
    private let pingTimeout: TimeInterval = 180
    private var watchdog: DispatchSourceTimer?

    override init() {
        super.init()
        smc = SMCConnection()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        timer.resume()
        watchdog = timer
    }

    private func watchdogTick() {
        guard manualActive, Date().timeIntervalSince(lastPing) > pingTimeout else { return }
        NSLog("floosh-fanhelper: kein Lebenszeichen der App — Lüfter zurück auf Automatik")
        _ = revertToAuto()
    }

    private func fanCount() -> Int {
        guard let smc else { return 0 }
        return SMCFans.count(smc)
    }

    private func revertToAuto() -> String? {
        guard let smc else { return "Keine SMC-Verbindung" }
        var firstError: String?
        for fan in 0..<fanCount() {
            do {
                try SMCFans.setAuto(smc, fan: fan)
            } catch {
                firstError = firstError ?? "\(error)"
            }
        }
        if firstError == nil { manualActive = false }
        return firstError
    }

    // MARK: FlooshFanHelperProtocol

    func setManual(percent: Double, reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            guard let smc else { reply("Keine SMC-Verbindung"); return }
            let count = fanCount()
            guard count > 0 else { reply("Keine Lüfter vorhanden"); return }
            var firstError: String?
            for fan in 0..<count {
                do {
                    try SMCFans.setManual(smc, fan: fan, percent: percent)
                } catch {
                    firstError = firstError ?? "\(error)"
                }
            }
            if firstError == nil {
                manualActive = true
                lastPing = Date()
            }
            reply(firstError)
        }
    }

    func setAuto(reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            reply(revertToAuto())
        }
    }

    func ping() {
        queue.async { [self] in lastPing = Date() }
    }

    func version(reply: @escaping @Sendable (Int) -> Void) {
        reply(fanHelperVersion)
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: FlooshFanHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
}

let helper = FanHelper()
let listener = NSXPCListener(machServiceName: fanHelperMachName)
// Nur Aufrufer mit der floosh-Bundle-ID akzeptieren (Best-Effort bei Ad-hoc-Signatur).
if #available(macOS 13.0, *) {
    try? listener.setConnectionCodeSigningRequirement("identifier \"digital.jrn.floosh\"")
}
listener.delegate = helper
listener.resume()
RunLoop.main.run()
