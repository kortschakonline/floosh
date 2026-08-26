import Foundation

/// Mach-Service-Name des privilegierten Lüfter-Helpers (LaunchDaemon).
public let fanHelperMachName = "digital.jrn.floosh.fanhelper"

/// Dateiname des Daemon-Plists im App-Bundle (Contents/Library/LaunchDaemons/).
public let fanHelperPlistName = "digital.jrn.floosh.fanhelper.plist"

/// Protokoll-Version — App und Helper müssen übereinstimmen.
public let fanHelperVersion = 1

/// XPC-Schnittstelle zwischen floosh und dem Root-Helper.
///
/// Sicherheitsnetz: Der Helper erwartet im Manuell-Modus regelmäßige `ping()`s.
/// Bleiben sie aus (App beendet/abgestürzt), stellt er die Lüfter selbstständig
/// zurück auf Automatik.
@objc public protocol FlooshFanHelperProtocol {
    /// Alle Lüfter auf feste Drehzahl stellen (0–100 % zwischen Min- und Max-RPM).
    /// `reply` liefert nil bei Erfolg, sonst eine Fehlerbeschreibung.
    func setManual(percent: Double, reply: @escaping @Sendable (String?) -> Void)

    /// Alle Lüfter zurück an die automatische Regelung geben.
    func setAuto(reply: @escaping @Sendable (String?) -> Void)

    /// Lebenszeichen der App — hält den Manuell-Modus aktiv.
    func ping()

    /// Protokoll-Version des laufenden Helpers.
    func version(reply: @escaping @Sendable (Int) -> Void)
}
