import Foundation
import IOKit

/// Liest kumulierte Lese-/Schreib-Bytes aller Blockspeicher-Treiber aus der IO-Registry.
enum DiskSampler {
    enum Kind {
        case internalDrive
        case externalDrive
        case virtualDrive // Disk-Images u. Ä.
    }

    struct Reading {
        let id: String
        let name: String
        let kind: Kind
        let bytesRead: UInt64
        let bytesWritten: UInt64
    }

    static func sample() -> [Reading] {
        var readings: [Reading] = []
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iter) == KERN_SUCCESS else { return readings }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["Statistics"] as? [String: Any] else { continue }

            let read = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let written = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0

            // Stabile ID über die Registry-Entry-ID des Treibers
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)

            // Gerätename + Anschlussort stehen am Eltern-Objekt (IOBlockStorageDevice)
            var name = "Laufwerk"
            var kind = Kind.internalDrive
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
                var parentProps: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(parent, &parentProps, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let pd = parentProps?.takeRetainedValue() as? [String: Any] {
                    if let dc = pd["Device Characteristics"] as? [String: Any],
                       let product = dc["Product Name"] as? String {
                        let trimmed = product.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { name = trimmed }
                    }
                    if let pc = pd["Protocol Characteristics"] as? [String: Any] {
                        let location = pc["Physical Interconnect Location"] as? String ?? ""
                        let interconnect = pc["Physical Interconnect"] as? String ?? ""
                        switch location {
                        case "External": kind = .externalDrive
                        case "File": kind = .virtualDrive
                        default: kind = interconnect == "Virtual Interface" ? .virtualDrive : .internalDrive
                        }
                    }
                }
                IOObjectRelease(parent)
            }

            readings.append(Reading(id: "disk-\(entryID)", name: name, kind: kind,
                                    bytesRead: read, bytesWritten: written))
        }
        return readings
    }
}
