import Foundation
import Darwin

/// Liest kumulierte In-/Out-Bytes aller Netzwerk-Interfaces über sysctl (NET_RT_IFLIST2).
enum NetSampler {
    struct Reading {
        let name: String
        let isLoopback: Bool
        let isVirtual: Bool // VPN-Tunnel, AWDL, Bridges usw.
        let bytesIn: UInt64
        let bytesOut: UInt64
    }

    /// Präfixe virtueller Interfaces (kein „echter" Datenverkehr nach außen bzw. doppelt gezählt)
    private static let virtualPrefixes = ["lo", "gif", "stf", "awdl", "llw", "utun", "anpi", "ap", "bridge", "vmnet", "feth"]

    static func sample() -> [Reading] {
        var readings: [Reading] = []
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return readings }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return readings }

        buf.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let msghdr = UnsafeRawPointer(base + offset).assumingMemoryBound(to: if_msghdr.self).pointee
                guard msghdr.ifm_msglen > 0 else { break }
                if Int32(msghdr.ifm_type) == RTM_IFINFO2 {
                    let if2 = UnsafeRawPointer(base + offset).assumingMemoryBound(to: if_msghdr2.self).pointee
                    var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(if2.ifm_index), &nameBuf) != nil {
                        let nameBytes = nameBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                        let name = String(decoding: nameBytes, as: UTF8.self)
                        let isLoop = Int32(if2.ifm_data.ifi_type) == IFT_LOOP
                        let isVirtual = virtualPrefixes.contains { prefix in
                            name.hasPrefix(prefix) && name.dropFirst(prefix.count).allSatisfy(\.isNumber)
                        }
                        readings.append(Reading(name: name,
                                                isLoopback: isLoop,
                                                isVirtual: isVirtual,
                                                bytesIn: if2.ifm_data.ifi_ibytes,
                                                bytesOut: if2.ifm_data.ifi_obytes))
                    }
                }
                offset += Int(msghdr.ifm_msglen)
            }
        }
        return readings
    }
}
