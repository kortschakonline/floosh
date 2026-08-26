import Foundation
import IOKit

// MARK: - SMC-Param-Struct (Layout muss exakt dem C-Struct des Kernels entsprechen: 80 Bytes)

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    // C-sizeof(SMCKeyInfoData) ist 12 — ohne diese Pad-Bytes verschiebt Swift
    // die Folgefelder und der Kernel liest Müll (alle Keys "nicht lesbar").
    var pad1: UInt8 = 0
    var pad2: UInt8 = 0
    var pad3: UInt8 = 0
}

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

// MARK: - Verbindung

/// Direkter Draht zum AppleSMC — Lesen geht ohne Privilegien,
/// Schreiben (Lüfter) verlangt Root und läuft daher im FlooshFanHelper.
public final class SMCConnection: @unchecked Sendable {
    public enum SMCError: Error, CustomStringConvertible {
        case callFailed(kern_return_t)
        case smcResult(UInt8)
        case keyNotFound(String)
        case typeMismatch(String)

        public var description: String {
            switch self {
            case .callFailed(let kr):
                kr == kIOReturnNotPrivileged
                    ? "Keine Berechtigung (Root erforderlich)"
                    : String(format: "IOKit-Fehler 0x%x", kr)
            case .smcResult(let r): String(format: "SMC-Fehler 0x%02x", r)
            case .keyNotFound(let k): "SMC-Key \(k) nicht vorhanden"
            case .typeMismatch(let k): "SMC-Key \(k) hat unerwarteten Typ"
            }
        }
    }

    private static let kIOReturnNotPrivilegedValue: kern_return_t = kern_return_t(bitPattern: 0xE00002C1)

    private var connection: io_connect_t = 0
    private let lock = NSLock()

    public init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
        guard kr == KERN_SUCCESS else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    // MARK: FourCC

    static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func fromFourCC(_ v: UInt32) -> String {
        let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                 UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: b, encoding: .ascii) ?? "????"
    }

    // MARK: Roh-Aufruf

    private func call(_ input: inout SMCParamStruct) throws(SMCError) -> SMCParamStruct {
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        lock.lock()
        let kr = IOConnectCallStructMethod(connection, 2, &input,
                                           MemoryLayout<SMCParamStruct>.stride,
                                           &output, &outSize)
        lock.unlock()
        guard kr == KERN_SUCCESS else { throw .callFailed(kr) }
        return output
    }

    private func keyInfo(_ key: String) throws(SMCError) -> SMCKeyInfoData {
        var p = SMCParamStruct()
        p.key = Self.fourCC(key)
        p.data8 = 9 // kSMCGetKeyInfo
        let out = try call(&p)
        guard out.result == 0 else { throw .keyNotFound(key) }
        return out.keyInfo
    }

    // MARK: Lesen

    public func readBytes(_ key: String) throws(SMCError) -> (type: String, bytes: [UInt8]) {
        let info = try keyInfo(key)
        var p = SMCParamStruct()
        p.key = Self.fourCC(key)
        p.keyInfo = info
        p.data8 = 5 // kSMCReadKey
        let out = try call(&p)
        guard out.result == 0 else { throw .smcResult(out.result) }
        var arr = [UInt8]()
        withUnsafeBytes(of: out.bytes) { raw in
            for i in 0..<Int(min(info.dataSize, 32)) { arr.append(raw[i]) }
        }
        return (Self.fromFourCC(info.dataType), arr)
    }

    public func readFloat(_ key: String) -> Float? {
        guard let (type, bytes) = try? readBytes(key), type == "flt ", bytes.count >= 4 else { return nil }
        var f: Float = 0
        _ = withUnsafeMutableBytes(of: &f) { bytes.copyBytes(to: $0, count: 4) }
        return f
    }

    public func readUInt8(_ key: String) -> UInt8? {
        guard let (type, bytes) = try? readBytes(key), type == "ui8 ", !bytes.isEmpty else { return nil }
        return bytes[0]
    }

    /// Alle Key-Namen des SMC (einmalige, etwas teurere Enumeration).
    public func allKeys() -> [String] {
        guard let (_, countBytes) = try? readBytes("#KEY"), countBytes.count >= 4 else { return [] }
        let count = (UInt32(countBytes[0]) << 24) | (UInt32(countBytes[1]) << 16)
                  | (UInt32(countBytes[2]) << 8) | UInt32(countBytes[3])
        guard count > 0, count < 20000 else { return [] }
        var keys: [String] = []
        keys.reserveCapacity(Int(count))
        for i in 0..<count {
            var p = SMCParamStruct()
            p.data8 = 8 // kSMCGetKeyFromIndex
            p.data32 = i
            guard let out = try? call(&p), out.result == 0 else { continue }
            keys.append(Self.fromFourCC(out.key))
        }
        return keys
    }

    // MARK: Schreiben (nur als Root erfolgreich)

    private func write(_ key: String, type: String, bytes: [UInt8]) throws(SMCError) {
        var p = SMCParamStruct()
        p.key = Self.fourCC(key)
        p.keyInfo = SMCKeyInfoData(dataSize: UInt32(bytes.count),
                                   dataType: Self.fourCC(type),
                                   dataAttributes: 0)
        p.data8 = 6 // kSMCWriteKey
        withUnsafeMutableBytes(of: &p.bytes) { raw in
            for (i, b) in bytes.prefix(32).enumerated() { raw[i] = b }
        }
        let out = try call(&p)
        guard out.result == 0 else { throw .smcResult(out.result) }
    }

    public func writeFloat(_ key: String, _ value: Float) throws(SMCError) {
        var v = value
        let bytes = withUnsafeBytes(of: &v) { Array($0) }
        try write(key, type: "flt ", bytes: bytes)
    }

    public func writeUInt8(_ key: String, _ value: UInt8) throws(SMCError) {
        try write(key, type: "ui8 ", bytes: [value])
    }
}

// MARK: - Lüfter-Helfer (gemeinsame Logik für App-Anzeige und Helper-Steuerung)

public enum SMCFans {
    /// Anzahl der Lüfter laut SMC (0 bei lüfterlosen Macs).
    public static func count(_ smc: SMCConnection) -> Int {
        Int(smc.readUInt8("FNum") ?? 0)
    }

    /// Setzt einen Lüfter auf manuelle Zieldrehzahl (Prozent von Min…Max). Root nötig.
    public static func setManual(_ smc: SMCConnection, fan: Int, percent: Double) throws(SMCConnection.SMCError) {
        let minRPM = smc.readFloat("F\(fan)Mn") ?? 0
        let maxRPM = smc.readFloat("F\(fan)Mx") ?? 0
        guard maxRPM > minRPM else { throw .keyNotFound("F\(fan)Mx") }
        let clamped = Float(min(max(percent, 0), 100)) / 100
        let target = minRPM + clamped * (maxRPM - minRPM)
        try smc.writeUInt8("F\(fan)Md", 1)
        try smc.writeFloat("F\(fan)Tg", target)
    }

    /// Gibt einen Lüfter an die automatische Regelung zurück. Root nötig.
    public static func setAuto(_ smc: SMCConnection, fan: Int) throws(SMCConnection.SMCError) {
        try smc.writeUInt8("F\(fan)Md", 0)
    }
}
