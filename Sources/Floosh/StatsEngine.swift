import Foundation
import Observation

/// Zentraler Mess-Motor: tastet Laufwerke + Netzwerk periodisch ab,
/// berechnet Raten aus Zähler-Deltas und hält den Verlauf für die Diagramme.
@MainActor
@Observable
final class StatsEngine {

    /// Eine Instanz für die ganze App — der AppDelegate braucht sie auch.
    static let shared = StatsEngine()

    struct GroupState {
        var read: Double = 0      // Bytes/s
        var write: Double = 0     // Bytes/s
        var samples: [Sample] = []
        var devices: [DeviceSpeed] = []
    }

    // MARK: Messwerte

    private(set) var groups: [SpeedGroup: GroupState] = [
        .internalDrives: GroupState(),
        .externalDrives: GroupState(),
        .network: GroupState(),
    ]
    private(set) var lastSampleDate = Date()

    /// CPU/GPU-Auslastung, Temperaturen und Lüfter (jede Runde neu abgetastet).
    private(set) var system = SystemSampler.Reading(cpuUsage: nil, gpuUsage: nil,
                                                    cpuTemp: nil, gpuTemp: nil, fans: [])
    var chipName: String { systemSampler.chipName }

    func state(for group: SpeedGroup) -> GroupState {
        groups[group] ?? GroupState()
    }

    /// Maximalwerte (Lesen, Schreiben) innerhalb des sichtbaren Zeitfensters.
    func windowMax(for group: SpeedGroup) -> (read: Double, write: Double) {
        let cutoff = lastSampleDate.addingTimeInterval(-chartWindow)
        let visible = state(for: group).samples.filter { $0.date >= cutoff }
        return (visible.map(\.read).max() ?? 0, visible.map(\.write).max() ?? 0)
    }

    // MARK: Einstellungen (persistiert in UserDefaults)

    var selectedGroup: SpeedGroup {
        didSet { defaults.set(selectedGroup.rawValue, forKey: "ds.group") }
    }
    var labelStyle: MenuLabelStyle {
        didSet { defaults.set(labelStyle.rawValue, forKey: "ds.labelStyle") }
    }
    var iconStyle: MenuIconStyle {
        didSet { defaults.set(iconStyle.rawValue, forKey: "ds.iconStyle") }
    }
    var units: SpeedUnits {
        didSet { defaults.set(units.rawValue, forKey: "ds.units") }
    }
    var interval: Double {
        didSet { defaults.set(interval, forKey: "ds.interval") }
    }
    var chartWindow: Double {
        didSet { defaults.set(chartWindow, forKey: "ds.window") }
    }
    var showDevices: Bool {
        didSet { defaults.set(showDevices, forKey: "ds.showDevices") }
    }
    var showPeaks: Bool {
        didSet { defaults.set(showPeaks, forKey: "ds.showPeaks") }
    }
    var includeVirtualDisks: Bool {
        didSet { defaults.set(includeVirtualDisks, forKey: "ds.virtualDisks") }
    }
    var includeVirtualNets: Bool {
        didSet { defaults.set(includeVirtualNets, forKey: "ds.virtualNets") }
    }
    var menuSystemStyle: MenuSystemStyle {
        didSet { defaults.set(menuSystemStyle.rawValue, forKey: "ds.menuSystem") }
    }
    var cardSize: CardSize {
        didSet { defaults.set(cardSize.rawValue, forKey: "ds.cardSize") }
    }
    var selectionStyle: SelectionStyle {
        didSet { defaults.set(selectionStyle.rawValue, forKey: "ds.selection") }
    }
    var layout: DropdownLayout {
        didSet { defaults.set(layout.rawValue, forKey: "ds.layout") }
    }
    /// Reihenfolge der Karten in Dropdown und Panel — frei sortierbar.
    var cardOrder: [DashboardCard] {
        didSet { defaults.set(cardOrder.map(\.rawValue), forKey: "ds.cardOrder") }
    }
    /// Deckkraft der Trägerfläche hinter den Karten (0 = nur die Karten,
    /// wie bis 1.6; 1 = geschlossene Fläche).
    var backdropOpacity: Double {
        didSet { defaults.set(backdropOpacity, forKey: "ds.backdrop") }
    }
    /// Zusätzliche Füllung hinter jeder Karte — macht das Glas kräftiger,
    /// ohne den Text blass zu machen (0 = reines Glas).
    var cardOpacity: Double {
        didSet { defaults.set(cardOpacity, forKey: "ds.cardOpacity") }
    }
    /// Breite des Dropdown-Fensters je nach Anordnung und Kachelgröße.
    var dropdownWidth: CGFloat {
        layout == .grid ? cardSize.gridWidth : cardSize.dropdownWidth
    }
    var menuChannel: MenuChannel {
        didSet { defaults.set(menuChannel.rawValue, forKey: "ds.menuChannel") }
    }
    var menuThermal: MenuThermalStyle {
        didSet { defaults.set(menuThermal.rawValue, forKey: "ds.menuThermal") }
    }
    var menuSparkline: Bool {
        didSet { defaults.set(menuSparkline, forKey: "ds.menuSparkline") }
    }
    var menuHideIdle: Bool {
        didSet { defaults.set(menuHideIdle, forKey: "ds.menuHideIdle") }
    }
    var menuTintText: Bool {
        didSet { defaults.set(menuTintText, forKey: "ds.menuTintText") }
    }

    // MARK: Intern

    private let defaults = UserDefaults.standard
    private var prevDisk: [String: (read: UInt64, write: UInt64)] = [:]
    private var prevNet: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
    private var lastTickUptime: TimeInterval?
    private var loop: Task<Void, Never>?
    private let maxHistory: TimeInterval = 200 // Sekunden Verlauf im Speicher
    private let systemSampler = SystemSampler()

    init() {
        selectedGroup = SpeedGroup(rawValue: defaults.string(forKey: "ds.group") ?? "") ?? .internalDrives
        labelStyle = MenuLabelStyle(rawValue: defaults.string(forKey: "ds.labelStyle") ?? "") ?? .split
        iconStyle = MenuIconStyle(rawValue: defaults.string(forKey: "ds.iconStyle") ?? "") ?? .outline
        units = SpeedUnits(rawValue: defaults.string(forKey: "ds.units") ?? "") ?? .bytes
        interval = defaults.object(forKey: "ds.interval") as? Double ?? 1.0
        chartWindow = defaults.object(forKey: "ds.window") as? Double ?? 60
        showDevices = defaults.object(forKey: "ds.showDevices") as? Bool ?? true
        showPeaks = defaults.object(forKey: "ds.showPeaks") as? Bool ?? true
        includeVirtualDisks = defaults.object(forKey: "ds.virtualDisks") as? Bool ?? false
        includeVirtualNets = defaults.object(forKey: "ds.virtualNets") as? Bool ?? false
        menuSystemStyle = MenuSystemStyle(rawValue: defaults.string(forKey: "ds.menuSystem") ?? "") ?? .off
        cardSize = CardSize(rawValue: defaults.string(forKey: "ds.cardSize") ?? "") ?? .medium
        selectionStyle = SelectionStyle(rawValue: defaults.string(forKey: "ds.selection") ?? "") ?? .border
        layout = DropdownLayout(rawValue: defaults.string(forKey: "ds.layout") ?? "") ?? .list
        cardOrder = Self.loadCardOrder(defaults)
        backdropOpacity = defaults.object(forKey: "ds.backdrop") as? Double ?? 0.5
        cardOpacity = defaults.object(forKey: "ds.cardOpacity") as? Double ?? 0.0
        menuChannel = MenuChannel(rawValue: defaults.string(forKey: "ds.menuChannel") ?? "") ?? .both
        menuThermal = MenuThermalStyle(rawValue: defaults.string(forKey: "ds.menuThermal") ?? "") ?? .off
        menuSparkline = defaults.object(forKey: "ds.menuSparkline") as? Bool ?? false
        menuHideIdle = defaults.object(forKey: "ds.menuHideIdle") as? Bool ?? false
        menuTintText = defaults.object(forKey: "ds.menuTintText") as? Bool ?? false
        start()
    }

    /// Gespeicherte Reihenfolge, ergänzt um Karten, die es damals noch nicht
    /// gab — so verschwindet nach einem Update keine neue Kachel.
    private static func loadCardOrder(_ defaults: UserDefaults) -> [DashboardCard] {
        let saved = (defaults.stringArray(forKey: "ds.cardOrder") ?? [])
            .compactMap(DashboardCard.init(rawValue:))
        return saved + DashboardCard.allCases.filter { !saved.contains($0) }
    }

    /// Sortiert eine Kartenauswahl nach der eingestellten Reihenfolge.
    func ordered(_ cards: some Collection<DashboardCard>) -> [DashboardCard] {
        cardOrder.filter(cards.contains)
    }

    /// Verschiebt eine Karte um eine Position (−1 hoch, +1 runter).
    func moveCard(_ card: DashboardCard, by offset: Int) {
        guard let from = cardOrder.firstIndex(of: card) else { return }
        let to = from + offset
        guard cardOrder.indices.contains(to) else { return }
        cardOrder.swapAt(from, to)
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                let ms = max(200, Int(self.interval * 1000))
                try? await Task.sleep(for: .milliseconds(ms))
            }
        }
    }

    // MARK: Abtastung

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let disks = DiskSampler.sample()
        let nets = NetSampler.sample()
        system = systemSampler.sample()
        FanService.shared.curveTick(cpuTemp: system.cpuTemp, gpuTemp: system.gpuTemp)

        defer { lastTickUptime = now }

        // Erste Runde: nur Zählerstände merken, noch keine Rate
        guard let last = lastTickUptime else {
            storeCounters(disks: disks, nets: nets)
            return
        }
        let dt = now - last
        guard dt > 0.05 else { return }

        var sums: [SpeedGroup: (read: Double, write: Double)] = [
            .internalDrives: (0, 0), .externalDrives: (0, 0), .network: (0, 0),
        ]
        var devices: [SpeedGroup: [DeviceSpeed]] = [
            .internalDrives: [], .externalDrives: [], .network: [],
        ]

        // Laufwerke
        var newPrevDisk: [String: (read: UInt64, write: UInt64)] = [:]
        for d in disks {
            newPrevDisk[d.id] = (d.bytesRead, d.bytesWritten)
            let group: SpeedGroup?
            switch d.kind {
            case .internalDrive: group = .internalDrives
            case .externalDrive: group = .externalDrives
            case .virtualDrive: group = includeVirtualDisks ? .internalDrives : nil
            }
            guard let group else { continue }
            let prev = prevDisk[d.id] ?? (d.bytesRead, d.bytesWritten)
            let dr = d.bytesRead >= prev.read ? d.bytesRead - prev.read : 0
            let dw = d.bytesWritten >= prev.write ? d.bytesWritten - prev.write : 0
            let readSpeed = Double(dr) / dt
            let writeSpeed = Double(dw) / dt
            sums[group]?.read += readSpeed
            sums[group]?.write += writeSpeed
            devices[group]?.append(DeviceSpeed(id: d.id, name: d.name, read: readSpeed, write: writeSpeed))
        }
        prevDisk = newPrevDisk

        // Netzwerk
        var newPrevNet: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        for n in nets {
            newPrevNet[n.name] = (n.bytesIn, n.bytesOut)
            guard !n.isLoopback else { continue }
            guard includeVirtualNets || !n.isVirtual else { continue }
            // Interfaces, über die noch nie Daten liefen (XHC*, tote en*), ausblenden
            guard n.bytesIn > 0 || n.bytesOut > 0 else { continue }
            let prev = prevNet[n.name] ?? (n.bytesIn, n.bytesOut)
            let di = n.bytesIn >= prev.bytesIn ? n.bytesIn - prev.bytesIn : 0
            let dout = n.bytesOut >= prev.bytesOut ? n.bytesOut - prev.bytesOut : 0
            let inSpeed = Double(di) / dt
            let outSpeed = Double(dout) / dt
            sums[.network]?.read += inSpeed
            sums[.network]?.write += outSpeed
            devices[.network]?.append(DeviceSpeed(id: "net-\(n.name)", name: n.name, read: inSpeed, write: outSpeed))
        }
        prevNet = newPrevNet

        // Zustände aktualisieren
        let date = Date()
        lastSampleDate = date
        let cutoff = date.addingTimeInterval(-maxHistory)
        for group in SpeedGroup.allCases {
            var state = groups[group] ?? GroupState()
            let sum = sums[group] ?? (0, 0)
            state.read = sum.read
            state.write = sum.write
            state.samples.append(Sample(date: date, read: sum.read, write: sum.write))
            state.samples.removeAll { $0.date < cutoff }
            state.devices = (devices[group] ?? []).sorted {
                ($0.read + $0.write, $1.name) > ($1.read + $1.write, $0.name)
            }
            groups[group] = state
        }
    }

    private func storeCounters(disks: [DiskSampler.Reading], nets: [NetSampler.Reading]) {
        prevDisk = Dictionary(uniqueKeysWithValues: disks.map { ($0.id, ($0.bytesRead, $0.bytesWritten)) })
        prevNet = Dictionary(uniqueKeysWithValues: nets.map { ($0.name, ($0.bytesIn, $0.bytesOut)) })
    }
}
