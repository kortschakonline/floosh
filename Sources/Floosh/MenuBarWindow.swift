import SwiftUI
import AppKit
import Observation

/// Eigener Menüleisten-Eintrag statt `MenuBarExtra`.
///
/// Grund für den Eigenbau: `MenuBarExtra` gibt seinen `NSStatusItem` nicht
/// heraus, und sein Fenster schließt sich, sobald eine andere App aktiv wird —
/// beides verhindert das Ablegen von Dateien. Hier nimmt der Eintrag selbst
/// Drags entgegen: Beim Darüberziehen klappt das Fenster auf (Spring-Loading),
/// abgelegt wird in der Ablage — auf dem Symbol oder irgendwo im Fenster.
@MainActor
final class MenuBarController: NSObject {

    private(set) static var shared: MenuBarController?

    private let engine: StatsEngine
    private let statusItem: NSStatusItem
    private var panel: NSPanel?
    private var dropView: StatusDropView?
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var closeTask: Task<Void, Never>?
    /// Fenster nur wegen eines laufenden Drags offen — schließt sich wieder,
    /// wenn der Drag woanders endet.
    private var openedForDrag = false

    @discardableResult
    static func start(engine: StatsEngine) -> MenuBarController {
        if let shared { return shared }
        let controller = MenuBarController(engine: engine)
        shared = controller
        return controller
    }

    init(engine: StatsEngine) {
        self.engine = engine
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.autosaveName = "digital.jrn.floosh.status"
        configureButton()
        observeLabel()
    }

    var isOpen: Bool { panel?.isVisible == true }
    var panelFrame: NSRect? { panel?.frame }

    // MARK: Menüleisten-Eintrag

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.image = LabelImageRenderer.render(engine.menuLabelSpec())

        // Transparente Ebene über dem Knopf: sie nimmt Klicks und Drags an
        // (an `NSStatusBarButton` selbst kommt man dafür nicht heran).
        // Zweiter Weg für den Klick: Bekommt die Drop-Ebene den Klick nicht,
        // greift die normale Knopf-Aktion — sonst wäre die App scheinbar tot.
        button.target = self
        button.action = #selector(statusButtonClicked)

        let drop = StatusDropView(frame: button.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.onClick = { [weak self] in self?.toggle() }
        drop.onDragEntered = { [weak self] in self?.springOpen() }
        drop.onDragExited = { [weak self] in self?.scheduleCloseAfterDrag() }
        drop.onDrop = { [weak self] urls in self?.accept(urls) ?? false }
        button.addSubview(drop)
        dropView = drop
    }

    @objc private func statusButtonClicked() {
        toggle()
    }

    /// Hält das Bild in der Menüleiste aktuell — `withObservationTracking`
    /// meldet jede Änderung an Messwerten und Einstellungen.
    private func observeLabel() {
        withObservationTracking { [self] in
            statusItem.button?.image = LabelImageRenderer.render(engine.menuLabelSpec())
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeLabel() }
        }
    }

    // MARK: Fenster

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        closeTask?.cancel()
        openedForDrag = false
        let panel = panel ?? makePanel()
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        startMonitors()
    }

    /// Beim Ziehen: aufklappen, ohne der aktiven App den Fokus zu nehmen —
    /// sonst bricht der laufende Drag ab.
    private func springOpen() {
        closeTask?.cancel()
        guard !isOpen else { return }
        openedForDrag = true
        let panel = panel ?? makePanel()
        position(panel)
        panel.orderFrontRegardless()
        statusItem.button?.highlight(true)
    }

    func close() {
        closeTask?.cancel()
        openedForDrag = false
        panel?.orderOut(nil)
        statusItem.button?.highlight(false)
        stopMonitors()
    }

    /// Der Drag hat den Eintrag verlassen: kurz warten (der Zeiger ist
    /// vielleicht auf dem Weg ins Fenster), sonst wieder zuklappen.
    private func scheduleCloseAfterDrag() {
        guard openedForDrag else { return }
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self, self.openedForDrag else { return }
            self.close()
        }
    }

    /// Das Fenster meldet, dass ein Drag darüber schwebt — nicht schließen.
    func dragEnteredPanel() {
        closeTask?.cancel()
    }

    /// Dateien sind angekommen: Fenster offen lassen, damit man sie sieht.
    @discardableResult
    func accept(_ urls: [URL]) -> Bool {
        closeTask?.cancel()
        let added = FileShelf.shared.add(urls)
        if added > 0, !FileShelf.shared.showInDropdown {
            // Sonst landet die Datei unsichtbar in der Ablage
            FileShelf.shared.showInDropdown = true
        }
        openedForDrag = false
        // `open()` startet auch die Überwachung fürs Schließen. Kam das
        // Fenster per Spring-Loading, ist es schon offen — dann lief bisher
        // keine Überwachung und es ließ sich nur noch über die Menüleiste
        // schließen. Deshalb hier immer nachziehen.
        if isOpen {
            startMonitors()
        } else {
            open()
        }
        return added > 0
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .utilityWindow

        let host = NSHostingController(rootView: DropdownView(engine: engine))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.setContentSize(host.view.fittingSize)

        // Inhalt wächst und schrumpft (Geräteliste, Ablage) — dann neu ausrichten
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                self.position(panel)
            }
        }
        self.panel = panel
        return panel
    }

    /// Unter dem Menüleisten-Eintrag ausrichten, am Bildschirmrand begrenzt.
    /// Ist der Eintrag nicht sichtbar (volle Menüleiste, zweite Instanz),
    /// klappt das Fenster oben rechts auf statt irgendwo.
    private func position(_ panel: NSPanel) {
        let screen = statusItem.button?.window?.screen ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        var x = visible.maxX - size.width - 8
        var y = visible.maxY - size.height - 6

        if let button = statusItem.button, let buttonWindow = button.window {
            let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            if anchor.width > 0, screen?.frame.intersects(anchor) ?? false {
                x = anchor.midX - size.width / 2
                y = anchor.minY - size.height - 6
            }
        }

        x = min(max(x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
        y = max(y, visible.minY + 8)
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    // MARK: Schließen bei Klick daneben

    private func startMonitors() {
        stopMonitors()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // Escape
                Task { @MainActor in self?.close() }
                return nil
            }
            return event
        }
    }

    private func stopMonitors() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        outsideMonitor = nil
        keyMonitor = nil
    }
}

// MARK: - Klick- und Drop-Ebene über dem Menüleisten-Symbol

/// Unsichtbare Ebene auf dem Status-Knopf: leitet Klicks weiter und nimmt
/// Datei-Drags entgegen.
final class StatusDropView: NSView {

    var onClick: (() -> Void)?
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
    var onDrop: (([URL]) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !Self.urls(from: sender).isEmpty else { return [] }
        onDragEntered?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.urls(from: sender).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExited?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(Self.urls(from: sender)) ?? false
    }

    static func urls(from sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

// MARK: - Einstellungen öffnen

/// Das Dropdown lebt außerhalb einer SwiftUI-Szene — `openSettings` aus der
/// Umgebung greift dort nicht. `showSettingsWindow:` meldet zwar Erfolg,
/// zeigt in dieser Konstellation aber kein Fenster; floosh öffnet die
/// Einstellungen deshalb selbst.
@MainActor
enum SettingsLauncher {
    static func open() {
        SettingsWindowController.shared.show(engine: .shared)
    }
}

/// Das Einstellungsfenster der App.
@MainActor
final class SettingsWindowController {

    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(engine: StatsEngine) {
        if window == nil {
            // Gleicher Aufbau wie im Shoot-Hook: Fenster zuerst, dann die
            // Hosting-View setzen. Über `contentViewController` stürzt AppKit
            // beim Aufbau der Tab-Leiste ab.
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "floosh"
            w.isReleasedWhenClosed = false
            w.toolbarStyle = .preference
            // Etwas breiter als die 440-pt-Form, sonst rutscht die Tab-Leiste
            // unter die Fensterknöpfe
            let host = NSHostingView(rootView:
                SettingsWindow(engine: engine, fixedHeight: false).frame(width: 520))
            // Idealhöhe messen, solange die Hosting-View noch ihre volle
            // Größe meldet …
            let ideal = host.fittingSize.height
            // … danach `.minSize`, damit das Fenster kleiner sein darf als der
            // längste Tab — sonst reicht es über den Bildschirmrand hinaus.
            host.sizingOptions = [.minSize]
            w.contentView = host
            let maxHeight = (NSScreen.screens.first?.visibleFrame.height ?? 900) - 60
            w.setContentSize(NSSize(width: 520, height: min(max(ideal, 320), maxHeight)))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
