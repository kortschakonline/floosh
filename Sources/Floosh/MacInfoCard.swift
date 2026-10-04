import SwiftUI
import AppKit
import IOKit

/// Was „Über diesen Mac" zeigt — einmal ermittelt (ändert sich nicht im Betrieb),
/// nur Laufzeit und freier Platz werden beim Anzeigen frisch gelesen.
struct MacInfo {
    let modelName: String      // „MacBook Pro"
    let modelDetail: String?   // „14", 2021"
    let chip: String           // „Apple M1 Pro"
    let memory: String         // „16 GB"
    let serial: String?
    let osName: String         // „Golden Gate 27.2"
    let osBuild: String

    static let current = MacInfo.read()

    private static func read() -> MacInfo {
        let identifier = sysctlString("hw.model") ?? "Mac"
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let memoryGB = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
                                        : "\(v.majorVersion).\(v.minorVersion)"
        let name = osNames[v.majorVersion].map { "\($0) \(version)" } ?? "macOS \(version)"
        let build = (try? String(contentsOfFile: "/System/Library/CoreServices/SystemVersion.plist", encoding: .utf8))
            .flatMap { plist -> String? in
                guard let range = plist.range(of: "<key>ProductBuildVersion</key>") else { return nil }
                let rest = plist[range.upperBound...]
                guard let start = rest.range(of: "<string>"), let end = rest.range(of: "</string>") else { return nil }
                return String(rest[start.upperBound..<end.lowerBound])
            } ?? ""
        let model = models[identifier]
        return MacInfo(modelName: model?.name ?? genericName(identifier),
                       modelDetail: model?.detail,
                       chip: chip,
                       memory: "\(memoryGB) GB",
                       serial: platformSerial(),
                       osName: name,
                       osBuild: build)
    }

    // MARK: Laufende Werte

    static var uptime: String {
        let total = Int(ProcessInfo.processInfo.systemUptime)
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        if days > 0 { return "\(days) Tag\(days == 1 ? "" : "e"), \(hours) h" }
        return "\(hours) h \((total % 3600) / 60) min"
    }

    /// Name und freier Platz des Startvolumes.
    static var startupVolume: (name: String, free: String?) {
        let url = URL(fileURLWithPath: "/")
        let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey])
        let name = values?.volumeName ?? FileManager.default.displayName(atPath: "/")
        let free = values?.volumeAvailableCapacityForImportantUsage.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        }
        return (name, free)
    }

    // MARK: Quellen

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func platformSerial() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformSerialNumber" as CFString,
                                               kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }

    private static func genericName(_ identifier: String) -> String {
        if identifier.hasPrefix("MacBookPro") { return "MacBook Pro" }
        if identifier.hasPrefix("MacBookAir") { return "MacBook Air" }
        if identifier.hasPrefix("Macmini") { return "Mac mini" }
        if identifier.hasPrefix("iMac") { return "iMac" }
        return "Mac"
    }

    /// Marketing-Namen von macOS — macOS selbst gibt sie nicht abfragbar heraus.
    private static let osNames: [Int: String] = [
        13: "Ventura", 14: "Sonoma", 15: "Sequoia", 26: "Tahoe", 27: "Golden Gate",
    ]

    /// Modell-Kennung → Name und Ausführung, wie „Über diesen Mac" sie zeigt.
    /// Unbekannte Kennungen: nur der Gerätetyp, ohne Zusatz.
    private static let models: [String: (name: String, detail: String)] = [
        "MacBookPro18,1": ("MacBook Pro", "16\u{2033}, 2021"),
        "MacBookPro18,2": ("MacBook Pro", "16\u{2033}, 2021"),
        "MacBookPro18,3": ("MacBook Pro", "14\u{2033}, 2021"),
        "MacBookPro18,4": ("MacBook Pro", "14\u{2033}, 2021"),
        "Mac14,5": ("MacBook Pro", "14\u{2033}, 2023"),
        "Mac14,9": ("MacBook Pro", "14\u{2033}, 2023"),
        "Mac14,6": ("MacBook Pro", "16\u{2033}, 2023"),
        "Mac14,10": ("MacBook Pro", "16\u{2033}, 2023"),
        "Mac15,3": ("MacBook Pro", "14\u{2033}, Nov. 2023"),
        "Mac15,6": ("MacBook Pro", "14\u{2033}, Nov. 2023"),
        "Mac16,1": ("MacBook Pro", "14\u{2033}, 2024"),
        "Mac16,6": ("MacBook Pro", "14\u{2033}, 2024"),
        "Mac16,5": ("MacBook Pro", "16\u{2033}, 2024"),
        "MacBookAir10,1": ("MacBook Air", "M1, 2020"),
        "Mac14,2": ("MacBook Air", "M2, 2022"),
        "Mac15,12": ("MacBook Air", "13\u{2033}, M3, 2024"),
        "Mac16,12": ("MacBook Air", "13\u{2033}, M4, 2025"),
        "Macmini9,1": ("Mac mini", "M1, 2020"),
        "Mac14,3": ("Mac mini", "2023"),
        "Mac14,12": ("Mac mini", "2023"),
        "Mac16,10": ("Mac mini", "2024"),
        "Mac16,11": ("Mac mini", "2024"),
        "iMac21,1": ("iMac", "24\u{2033}, M1, 2021"),
        "Mac15,4": ("iMac", "24\u{2033}, 2023"),
        "Mac16,2": ("iMac", "24\u{2033}, 2024"),
    ]
}

/// Kachel „Dieser Mac": Gerätebild, Modell, Chip, Speicher, Startvolume,
/// Seriennummer (verdeckt, Klick zeigt sie), macOS und Laufzeit.
struct MacInfoCard: View {
    let engine: StatsEngine
    @State private var showSerial = false

    private var size: CardSize { engine.cardSize }
    private let info = MacInfo.current

    var body: some View {
        // Laufzeit und freier Platz bei jeder Messrunde frisch
        let _ = engine.lastSampleDate
        let volume = MacInfo.startupVolume
        VStack(alignment: .leading, spacing: size.spacing) {
            HStack(alignment: .center, spacing: 14) {
                // Breiter als hoch: Flache Geräte wie der Mac mini füllen so
                // die Breite aus, statt im Quadrat winzig zu wirken
                Image(nsImage: NSImage(named: NSImage.computerName) ?? NSImage())
                    .resizable()
                    .scaledToFit()
                    .frame(width: imageSize.width, height: imageSize.height)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.modelName)
                        .font(size.titleFont)
                    if let detail = info.modelDetail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                row("Chip", info.chip)
                row("Speicher", info.memory)
                row("Startvolume", volume.free.map { "\(volume.name) · \($0) frei" } ?? volume.name)
                GridRow {
                    label("Seriennummer")
                    Button {
                        showSerial.toggle()
                    } label: {
                        Text(showSerial ? (info.serial ?? "–") : "•••••••••• (zeigen)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    .buttonStyle(.plain)
                    .help(showSerial ? "Seriennummer ausblenden" : "Seriennummer zeigen")
                }
                row("macOS", info.osBuild.isEmpty ? info.osName : "\(info.osName) (\(info.osBuild))")
                row("Laufzeit", MacInfo.uptime)
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(size.padding)
        .cardGlass(cornerRadius: size.cornerRadius)
    }

    private var imageSize: CGSize {
        switch size {
        case .small: CGSize(width: 76, height: 60)
        case .medium: CGSize(width: 96, height: 76)
        case .large: CGSize(width: 112, height: 88)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            label(title)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}
