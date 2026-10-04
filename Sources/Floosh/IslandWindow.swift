import SwiftUI
import AppKit
import Observation

// MARK: - Einstellungen

/// Was links und rechts neben der Notch in Ruhe steht.
enum IslandValue: String, CaseIterable, Identifiable {
    case none, network, disk, cpuTemp, battery

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "Nichts"
        case .network: "Netzwerk ↓"
        case .disk: "Laufwerke (Lesen + Schreiben)"
        case .cpuTemp: "CPU-Temperatur"
        case .battery: "Akku"
        }
    }
}

@MainActor
@Observable
final class IslandSettings {
    static let shared = IslandSettings()

    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "island.enabled"); IslandController.shared.rebuild() }
    }
    /// Auf Bildschirmen ohne Notch als Pille mitten in der Menüleiste.
    var showWithoutNotch: Bool {
        didSet { defaults.set(showWithoutNotch, forKey: "island.pill"); IslandController.shared.rebuild() }
    }
    var left: IslandValue {
        didSet { defaults.set(left.rawValue, forKey: "island.left") }
    }
    var right: IslandValue {
        didSet { defaults.set(right.rawValue, forKey: "island.right") }
    }
    /// Kurze Hinweise (Laufwerk, Netzteil, Akku niedrig).
    var alerts: Bool {
        didSet { defaults.set(alerts, forKey: "island.alerts") }
    }
    /// Beim Darüberfahren leicht aufklappen.
    var hoverPeek: Bool {
        didSet { defaults.set(hoverPeek, forKey: "island.hover") }
    }

    private let defaults = UserDefaults.standard

    private init() {
        enabled = defaults.object(forKey: "island.enabled") as? Bool ?? true
        showWithoutNotch = defaults.object(forKey: "island.pill") as? Bool ?? true
        left = IslandValue(rawValue: defaults.string(forKey: "island.left") ?? "") ?? .network
        right = IslandValue(rawValue: defaults.string(forKey: "island.right") ?? "") ?? .cpuTemp
        alerts = defaults.object(forKey: "island.alerts") as? Bool ?? true
        hoverPeek = defaults.object(forKey: "island.hover") as? Bool ?? true
    }
}

// MARK: - Zustand

enum IslandTab: String, CaseIterable, Identifiable {
    case live, shelf, music, battery, menubar, tools

    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: "Live"
        case .shelf: "Ablage"
        case .music: "Musik"
        case .battery: "Akku"
        case .menubar: "Menüleiste"
        case .tools: "Werkzeuge"
        }
    }
    var symbol: String {
        switch self {
        case .live: "waveform.path.ecg"
        case .shelf: "tray"
        case .music: "music.note"
        case .battery: "battery.75percent"
        case .menubar: "menubar.rectangle"
        case .tools: "wrench.and.screwdriver"
        }
    }
}

struct IslandAlert: Equatable {
    var symbol: String
    var color: Color
    var text: String
}

@MainActor
@Observable
final class IslandModel {
    enum Mode: Equatable { case idle, peek, expanded, alert }

    var mode: Mode = .idle
    var tab: IslandTab = .live
    var alert: IslandAlert?
    /// Gerade werden Dateien über die Island gezogen.
    var isDropTarget = false
    /// Echte Notch (sonst Pille in der Menüleiste).
    var hasNotch = true
    /// Größe der Notch bzw. der Pille in Ruhe (ohne Seitenwerte).
    var core = CGSize(width: 185, height: 32)

    /// Breite der Seitenfelder links/rechts in Ruhe.
    var sideWidth: CGFloat {
        let s = IslandSettings.shared
        return (s.left == .none && s.right == .none) ? 0 : 74
    }

    /// Ohren an den oberen Ecken der Notch-Form (gehen in die Menüleiste über).
    static let ear: CGFloat = 8

    /// Sichtbare Größe der Form je Zustand.
    func size(for mode: Mode) -> CGSize {
        let ear = hasNotch ? Self.ear * 2 : 0
        switch mode {
        case .idle:
            return CGSize(width: core.width + 2 * sideWidth + ear, height: core.height)
        case .alert:
            return CGSize(width: core.width + 2 * 180 + ear, height: core.height)
        case .peek:
            return CGSize(width: max(core.width + 2 * sideWidth + ear, 380), height: core.height + 44)
        case .expanded:
            // Kopfzeile mit Tabs (~40) + Inhalt je Tab + Rand unten
            let content: CGFloat = switch tab {
            case .live: 78
            case .tools, .menubar: 104
            case .shelf, .music, .battery: 124
            }
            return CGSize(width: 580, height: core.height + 40 + content + 24)
        }
    }

    var currentSize: CGSize { size(for: mode) }
}

// MARK: - Fenster

/// Die floosh-Island: ein randloses Fenster über der Menüleiste, oben mittig
/// auf dem Bildschirm mit Notch (sonst als Pille mitten in der Menüleiste).
///
/// Das Fenster ist so groß wie die aufgeklappte Island, lässt Klicks aber
/// überall durch, wo gerade keine Island zu sehen ist (`ignoresMouseEvents`
/// je nach Zeigerposition) — die Menüleiste darunter bleibt bedienbar.
@MainActor
final class IslandController {
    static let shared = IslandController()

    let model = IslandModel()
    private var engine: StatsEngine?
    private var panel: NSPanel?
    private var screen: NSScreen?
    private var monitors: [Any] = []
    private var hoverTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var alertTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var openedForDrag = false
    /// Dev-Hook (`--shoot island`): offen lassen, egal wo der Zeiger ist.
    var holdOpen = false

    // Zustand für Hinweise
    private var lastExternalCount: Int?
    private var lastPluggedIn: Bool?
    private var lastBatteryPercent: Int?

    private static let panelSize = CGSize(width: 700, height: 300)

    var panelFrame: NSRect? { panel?.frame }

    func attach(engine: StatsEngine) {
        self.engine = engine
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { _ in
            Task { @MainActor in IslandController.shared.rebuild() }
        }
        rebuild()
    }

    /// Bildschirm wählen und Fenster (neu) aufbauen — beim Start, bei
    /// Monitor-Änderungen und wenn die Einstellungen sich ändern.
    func rebuild() {
        let settings = IslandSettings.shared
        DragCatcher.shared.islandListening = settings.enabled && engine != nil
        guard let engine, settings.enabled else { teardown(); return }

        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        guard let target = notched ?? (settings.showWithoutNotch ? (NSScreen.main ?? NSScreen.screens.first) : nil)
        else { teardown(); return }
        screen = target

        if let notched, notched == target,
           let leftArea = notched.auxiliaryTopLeftArea, let rightArea = notched.auxiliaryTopRightArea {
            model.hasNotch = true
            model.core = CGSize(width: rightArea.minX - leftArea.maxX, height: notched.safeAreaInsets.top)
        } else {
            model.hasNotch = false
            let menuBar = target.frame.maxY - target.visibleFrame.maxY
            model.core = CGSize(width: 120, height: max(22, min(menuBar, 37) - 6))
        }

        let panel = panel ?? makePanel(engine: engine)
        let midX = notchMidX(on: target)
        let size = Self.panelSize
        panel.setFrame(NSRect(x: midX - size.width / 2, y: target.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        startMonitors()
        startWatching()
        updateMouseThrough()
    }

    private func teardown() {
        panel?.orderOut(nil)
        stopMonitors()
        watchTask?.cancel()
        watchTask = nil
        NowPlaying.shared.setActive(false)
    }

    private func notchMidX(on screen: NSScreen) -> CGFloat {
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            return (l.maxX + r.minX) / 2
        }
        return screen.frame.midX
    }

    private func makePanel(engine: StatsEngine) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Über der Menüleiste, damit die Island die Notch überdecken kann
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: IslandView(model: model, engine: engine))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }

    // MARK: Zeiger

    /// Bildschirmbereich, in dem die Island gerade Klicks annimmt. In Ruhe
    /// nur die Notch selbst — die Seitenwerte liegen über der Menüleiste und
    /// sollen deren Klicks nicht schlucken.
    private var interactiveRect: NSRect {
        guard let screen else { return .zero }
        let midX = notchMidX(on: screen)
        let size: CGSize = model.mode == .idle || model.mode == .alert
            ? CGSize(width: model.core.width, height: model.core.height)
            : model.currentSize
        return NSRect(x: midX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    private func startMonitors() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            Task { @MainActor in IslandController.shared.handle(event, local: false) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            Task { @MainActor in IslandController.shared.handle(event, local: true) }
            return event
        }) { monitors.append(local) }
    }

    private func stopMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handle(_ event: NSEvent, local: Bool) {
        let inside = interactiveRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        updateMouseThrough()

        // Klick daneben schließt die offene Island
        if !holdOpen, event.type == .leftMouseDown || event.type == .rightMouseDown {
            if !inside, model.mode == .expanded { setMode(.idle) }
            return
        }

        if holdOpen { return }
        if inside {
            collapseTask?.cancel()
            if model.mode == .idle || model.mode == .alert, IslandSettings.shared.hoverPeek, hoverTask == nil {
                hoverTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(140))
                    guard !Task.isCancelled, let self else { return }
                    self.hoverTask = nil
                    if self.interactiveRect.contains(NSEvent.mouseLocation),
                       self.model.mode == .idle || self.model.mode == .alert {
                        self.setMode(.peek)
                    }
                }
            }
        } else {
            hoverTask?.cancel()
            hoverTask = nil
            switch model.mode {
            case .peek:
                setMode(.idle)
            case .expanded where !openedForDrag:
                // Kurz Zeit lassen — der Zeiger rutscht beim Bedienen gern raus
                guard collapseTask == nil else { return }
                collapseTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled, let self else { return }
                    self.collapseTask = nil
                    if !self.interactiveRect.contains(NSEvent.mouseLocation) { self.setMode(.idle) }
                }
            default:
                break
            }
        }
    }

    private func updateMouseThrough() {
        guard let panel else { return }
        let inside = interactiveRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        // Beim Ziehen von Dateien muss das Fenster Drags annehmen können
        let accept = inside || (model.isDropTarget || openedForDrag)
        if panel.ignoresMouseEvents == accept { panel.ignoresMouseEvents = !accept }
    }

    func setMode(_ mode: IslandModel.Mode) {
        collapseTask?.cancel()
        collapseTask = nil
        if mode != .expanded { openedForDrag = false }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
            model.mode = mode
        }
        NowPlaying.shared.setActive(mode == .expanded || mode == .peek)
        updateMouseThrough()
    }

    /// Klick auf die Island: ganz aufklappen bzw. wieder zu.
    func toggleExpanded() {
        setMode(model.mode == .expanded ? .idle : .expanded)
    }

    // MARK: Datei-Drags

    /// Vom DragCatcher gemeldet: irgendwo im System werden Dateien gezogen.
    func dragChanged(_ dragging: Bool) {
        guard panel?.isVisible == true else { return }
        if dragging {
            guard model.mode != .expanded else { return }
            openedForDrag = true
            model.tab = .shelf
            setMode(.expanded)
        } else if openedForDrag {
            // Drop wird erst nach dem Loslassen zugestellt — kurz offen lassen
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1200))
                guard let self, self.openedForDrag else { return }
                self.openedForDrag = false
                if !self.interactiveRect.contains(NSEvent.mouseLocation) { self.setMode(.idle) }
            }
        }
        updateMouseThrough()
    }

    // MARK: Hinweise

    /// Einmal pro Sekunde auf Ereignisse prüfen, die einen Hinweis wert sind.
    private func startWatching() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.checkEvents()
            }
        }
    }

    private func checkEvents() {
        guard let engine else { return }
        let external = engine.state(for: .externalDrives).devices
        if let last = lastExternalCount, external.count > last, let device = external.last {
            show(IslandAlert(symbol: "externaldrive.fill.badge.plus", color: .orange,
                             text: "\(device.name) angeschlossen"))
        }
        lastExternalCount = external.count

        if let battery = engine.battery {
            if let last = lastPluggedIn, last != battery.isPluggedIn {
                if battery.isPluggedIn {
                    let watts = battery.adapterWatts.map { " · \($0) W" } ?? ""
                    show(IslandAlert(symbol: "bolt.fill", color: .green, text: "Netzteil angeschlossen\(watts)"))
                } else {
                    show(IslandAlert(symbol: "battery.75percent", color: .white,
                                     text: "Akkubetrieb · \(battery.percent) %"))
                }
            }
            if let last = lastBatteryPercent, !battery.isPluggedIn {
                for level in [20, 10] where last > level && battery.percent <= level {
                    show(IslandAlert(symbol: "battery.25percent", color: level == 10 ? .red : .orange,
                                     text: "Akku \(battery.percent) % — Netzteil anschließen"))
                }
            }
            lastPluggedIn = battery.isPluggedIn
            lastBatteryPercent = battery.percent
        }
    }

    func show(_ alert: IslandAlert) {
        guard IslandSettings.shared.alerts, model.mode == .idle || model.mode == .alert else { return }
        alertTask?.cancel()
        model.alert = alert
        setMode(.alert)
        alertTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled, let self, self.model.mode == .alert else { return }
            self.setMode(.idle)
        }
    }
}
