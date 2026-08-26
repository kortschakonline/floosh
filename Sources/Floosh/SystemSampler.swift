import Foundation
import IOKit
#if canImport(FlooshShared)
import FlooshShared
#endif

/// Tastet CPU-/GPU-Auslastung, Die-Temperaturen und Lüfter ab.
///
/// Temperaturen kommen aus dem SMC: `Tp*` sind CPU-, `Tg*` GPU-Sensoren.
/// Auf Apple Silicon liegt jeder physische Sensor als Dreiergruppe
/// aufeinanderfolgender Keys mit festen Kalibrier-Offsets (+~9 °C) vor —
/// nur der jeweils erste Key der Gruppe ist die reale Temperatur.
final class SystemSampler {

    struct Reading {
        var cpuUsage: Double?    // 0…1
        var gpuUsage: Double?    // 0…1
        var cpuTemp: Double?     // °C
        var gpuTemp: Double?     // °C
        var fans: [FanReading]
    }

    struct FanReading: Identifiable {
        let id: Int
        let rpm: Double
        let minRPM: Double
        let maxRPM: Double
        let targetRPM: Double
        let isManual: Bool
    }

    private let smc = SMCConnection()
    private let cpuTempKeys: [String]
    private let gpuTempKeys: [String]
    private let fanCount: Int
    private var prevCPUTicks: [(busy: UInt64, total: UInt64)] = []

    /// Chip-Name für die Anzeige, z. B. „Apple M1 Pro".
    let chipName: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf, encoding: .utf8) ?? "CPU"
    }()

    init() {
        if let smc {
            let keys = Set(smc.allKeys())
            cpuTempKeys = Self.baseSensorKeys(prefix: "Tp", in: keys)
            gpuTempKeys = Self.baseSensorKeys(prefix: "Tg", in: keys)
            fanCount = SMCFans.count(smc)
        } else {
            cpuTempKeys = []
            gpuTempKeys = []
            fanCount = 0
        }
    }

    /// Filtert aus `Tp00 Tp01 Tp02 Tp04 …` die Basis-Keys der Dreiergruppen
    /// (Tp00, Tp04, …) heraus; Chips ohne Gruppen bleiben unverändert.
    static func baseSensorKeys(prefix: String, in keys: Set<String>) -> [String] {
        let candidates = keys.filter { $0.hasPrefix(prefix) && $0.count == 4 }.sorted()
        var consumed = Set<String>()
        var bases: [String] = []
        for key in candidates {
            guard !consumed.contains(key) else { continue }
            bases.append(key)
            if let s1 = successor(key), candidates.contains(s1) {
                consumed.insert(s1)
                if let s2 = successor(s1), candidates.contains(s2) {
                    consumed.insert(s2)
                }
            }
        }
        return bases
    }

    /// Nachfolger des letzten Zeichens in der SMC-Key-Ordnung 0–9 < A–Z < a–z.
    private static func successor(_ key: String) -> String? {
        guard let last = key.last, let ascii = last.asciiValue else { return nil }
        let next: UInt8?
        switch last {
        case "9": next = UInt8(ascii: "A")
        case "Z": next = UInt8(ascii: "a")
        case "z": next = nil
        default: next = ascii + 1
        }
        guard let next else { return nil }
        return String(key.dropLast()) + String(UnicodeScalar(next))
    }

    // MARK: Abtastung

    func sample() -> Reading {
        Reading(cpuUsage: cpuUsage(),
                gpuUsage: Self.gpuUsage(),
                cpuTemp: maxTemp(of: cpuTempKeys),
                gpuTemp: maxTemp(of: gpuTempKeys),
                fans: fanReadings())
    }

    private func maxTemp(of keys: [String]) -> Double? {
        guard let smc else { return nil }
        let values = keys.compactMap { smc.readFloat($0) }.map(Double.init)
            .filter { $0 > 5 && $0 < 130 }
        return values.max()
    }

    private func fanReadings() -> [FanReading] {
        guard let smc, fanCount > 0 else { return [] }
        return (0..<fanCount).map { i in
            FanReading(id: i,
                       rpm: Double(smc.readFloat("F\(i)Ac") ?? 0),
                       minRPM: Double(smc.readFloat("F\(i)Mn") ?? 0),
                       maxRPM: Double(smc.readFloat("F\(i)Mx") ?? 0),
                       targetRPM: Double(smc.readFloat("F\(i)Tg") ?? 0),
                       isManual: (smc.readUInt8("F\(i)Md") ?? 0) != 0)
        }
    }

    // MARK: CPU-Auslastung (Delta der Tick-Zähler aller Kerne)

    private func cpuUsage() -> Double? {
        var count = mach_msg_type_number_t(0)
        var cpuCount = natural_t(0)
        var info: processor_info_array_t?
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &cpuCount, &info, &count)
        guard kr == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        var ticks: [(busy: UInt64, total: UInt64)] = []
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            ticks.append((user + system + nice, user + system + nice + idle))
        }

        defer { prevCPUTicks = ticks }
        guard prevCPUTicks.count == ticks.count else { return nil }

        var busy: Double = 0
        var total: Double = 0
        for (now, prev) in zip(ticks, prevCPUTicks) {
            busy += Double(now.busy &- prev.busy)
            total += Double(now.total &- prev.total)
        }
        guard total > 0 else { return nil }
        return min(max(busy / total, 0), 1)
    }

    // MARK: GPU-Auslastung (IOAccelerator-Statistik)

    private static func gpuUsage() -> Double? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            let kr = IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0)
            IOObjectRelease(entry)
            if kr == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let stats = dict["PerformanceStatistics"] as? [String: Any],
               let util = stats["Device Utilization %"] as? Int {
                return min(max(Double(util) / 100, 0), 1)
            }
            entry = IOIteratorNext(iterator)
        }
        return nil
    }
}
