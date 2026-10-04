import Foundation
import IOKit

/// Liest den Akku aus der IORegistry (`AppleSmartBattery`) — ohne Root.
///
/// Die interessanten Werte für „warum lädt das so lange?": Was das Netzteil
/// liefern *könnte* (`AdapterDetails.Watts`), was tatsächlich ins System
/// fließt (`PowerTelemetryData.SystemPowerIn`) und was davon im Akku ankommt
/// (Strom × Spannung). Die Rohkapazitäten stehen seit macOS 27 nur noch unter
/// `BatteryData`, nicht mehr auf der obersten Ebene.
final class BatterySampler {

    struct Reading: Equatable {
        /// Ladestand 0…100 (wie in der Menüleiste).
        var percent: Int
        var isCharging: Bool
        var isPluggedIn: Bool
        var isFull: Bool
        /// Leistung in den Akku (W): positiv = laden, negativ = entladen.
        var batteryWatts: Double
        /// Nennleistung des Netzteils (W), falls angeschlossen.
        var adapterWatts: Int?
        var adapterName: String?
        /// Was gerade tatsächlich vom Netzteil ins System fließt (W).
        var systemInWatts: Double?
        /// Verbrauch des Macs ohne Akku-Laden (W).
        var systemLoadWatts: Double?
        /// Minuten bis voll bzw. leer laut macOS (`nil` = wird noch berechnet).
        var minutesToFull: Int?
        var minutesToEmpty: Int?
        /// Zustand: aktuelle Volladekapazität im Verhältnis zur Auslegung (0…1).
        var health: Double?
        var cycleCount: Int?
        /// mAh: aktuell gespeichert und bei voll — für „Zeit bis 80 %".
        var remainingMAh: Int?
        var fullMAh: Int?
        /// mA in den Akku (positiv beim Laden).
        var amperage: Int
        /// macOS meldet einen Grund, warum trotz Netzteil nicht geladen wird
        /// (z. B. optimiertes Laden, Temperatur).
        var notChargingReason: Int
        var slowChargingReason: Int

        /// Minuten bis 80 % aus Kapazität und aktuellem Ladestrom geschätzt.
        var minutesTo80: Int? {
            guard isCharging, percent < 80, amperage > 50,
                  let remainingMAh, let fullMAh, fullMAh > 0 else { return nil }
            let missing = Double(fullMAh) * 0.8 - Double(remainingMAh)
            guard missing > 0 else { return nil }
            return Int((missing / Double(amperage) * 60).rounded())
        }
    }

    /// `nil`, wenn der Mac keinen Akku hat (Mac mini, iMac, Studio).
    func sample() -> Reading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        guard props["BatteryInstalled"] as? Bool ?? true else { return nil }

        func int(_ dict: [String: Any], _ key: String) -> Int? {
            (dict[key] as? NSNumber)?.intValue
        }

        let data = props["BatteryData"] as? [String: Any] ?? [:]
        let adapter = props["AdapterDetails"] as? [String: Any] ?? [:]
        let telemetry = props["PowerTelemetryData"] as? [String: Any] ?? [:]
        let charger = props["ChargerData"] as? [String: Any] ?? [:]

        let amperage = int(props, "InstantAmperage") ?? int(props, "Amperage") ?? 0
        let voltage = int(props, "Voltage") ?? int(props, "AppleRawBatteryVoltage") ?? 0
        let plugged = props["ExternalConnected"] as? Bool ?? false

        // Zeiten: 65535 heißt „noch unbekannt"
        func minutes(_ key: String) -> Int? {
            guard let value = int(props, key), value > 0, value < 65535 else { return nil }
            return value
        }

        let design = int(data, "DesignCapacity") ?? int(props, "DesignCapacity")
        let nominal = int(data, "NominalChargeCapacity") ?? int(props, "NominalChargeCapacity")
        let health: Double? = {
            guard let design, design > 0, let nominal else { return nil }
            return min(Double(nominal) / Double(design), 1.2)
        }()

        let watts = adapter["Watts"].flatMap { ($0 as? NSNumber)?.intValue }

        return Reading(
            percent: int(props, "CurrentCapacity") ?? 0,
            isCharging: props["IsCharging"] as? Bool ?? false,
            isPluggedIn: plugged,
            isFull: props["FullyCharged"] as? Bool ?? false,
            batteryWatts: Double(amperage) * Double(voltage) / 1_000_000,
            adapterWatts: plugged ? watts : nil,
            adapterName: plugged ? (adapter["Name"] as? String) : nil,
            systemInWatts: plugged ? int(telemetry, "SystemPowerIn").map { Double($0) / 1000 } : nil,
            systemLoadWatts: int(telemetry, "SystemLoad").map { Double($0) / 1000 },
            minutesToFull: minutes("AvgTimeToFull"),
            minutesToEmpty: minutes("AvgTimeToEmpty"),
            health: health,
            cycleCount: int(props, "CycleCount"),
            remainingMAh: int(data, "RemainingCapacity") ?? int(props, "AppleRawCurrentCapacity"),
            fullMAh: int(data, "FullChargeCapacity") ?? int(props, "AppleRawMaxCapacity"),
            amperage: amperage,
            notChargingReason: int(charger, "NotChargingReason") ?? 0,
            slowChargingReason: int(charger, "SlowChargingReason") ?? 0
        )
    }
}
