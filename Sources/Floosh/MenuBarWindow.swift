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
    private var statusItem: NSStatusItem
    private var panel: NSPanel?
    private var dropView: StatusDropView?
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var closeTask: Task<Void, Never>?
    /// Fenster nur wegen eines laufenden Drags offen — schließt sich wieder,
    /// wenn der Drag woanders endet.
    private var openedForDrag = false

    /// Losgelöstes Fenster: obere linke Ecke, wohin es gezogen wurde. Dann
    /// bleibt es dort und schließt nicht beim Klick daneben. `nil` = angedockt.
    private var detachedTopLeft: NSPoint? {
        didSet {
            if let p = detachedTopLeft {
                UserDefaults.standard.set([Double(p.x), Double(p.y)], forKey: "menu.topLeft")
            } else {
                UserDefaults.standard.removeObject(forKey: "menu.topLeft")
            }
        }
    }
    /// Breite zu Beginn eines Zugs an einem Eck-Griff.
    private var gripStartWidth: CGFloat = 0

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
        let defaults = UserDefaults.standard
        if let p = defaults.array(forKey: "menu.topLeft") as? [Double], p.count == 2 {
            detachedTopLeft = NSPoint(x: p[0], y: p[1])
        }
        // Bis 1.8.0-Testbau gab es eine gezogene Höhe — sie schnitt Kacheln ab
        defaults.removeObject(forKey: "menu.height")
        configureButton()
        observeLabel()
    }

    /// Symbol neu anlegen, damit eine frisch gesetzte Startposition greift
    /// (macOS liest sie nur beim Anlegen) — genutzt vom Menüleisten-Organizer.
    func recreateStatusItem() {
        close()
        // macOS löscht beim Entfernen die gemerkte Position — vorher sichern
        let key = "NSStatusItem Preferred Position digital.jrn.floosh.status"
        let position = UserDefaults.standard.object(forKey: key)
        NSStatusBar.system.removeStatusItem(statusItem)
        if let position { UserDefaults.standard.set(position, forKey: key) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "digital.jrn.floosh.status"
        configureButton()
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
        engine.fitColumns = nil // bei jedem Öffnen neu ermitteln
        applyContentSize(measureContent(), to: panel)
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
        applyContentSize(measureContent(), to: panel)
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
                            styleMask: [.borderless, .nonactivatingPanel, .resizable],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Verschoben wird nur über den Griff im Kopf (`WindowDragHandle`)
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self

        // Die Fenstergröße setzt der Controller selbst (`applyContentSize`),
        // nicht SwiftUI über `.preferredContentSize`: Diese Rückkopplung
        // (Fenstergröße → Layout → Fenstergröße) blieb unter macOS 27.2 Beta
        // in einer Endlosschleife hängen, das Fenster erschien nie.
        // Gemessen wird der Inhalt im ScrollView, also unabhängig von der
        // Fenstergröße — damit kann sich nichts mehr aufschaukeln.
        let host = NSHostingController(rootView: MenuPanelContent(engine: engine) { [weak self] size in
            guard let self, let panel = self.panel else { return }
            self.applyContentSize(size, to: panel)
        })
        host.sizingOptions = []
        panel.contentViewController = host
        self.panel = panel
        return panel
    }

    /// Idealgröße des Inhalts, gemessen ohne Fenster — für den ersten Auftritt,
    /// bevor das Fenster selbst eine Messung melden kann.
    private func measureContent() -> CGSize {
        NSHostingView(rootView: DropdownView(engine: engine)).fittingSize
    }

    /// Fenster auf die Inhaltsgröße bringen, höchstens so hoch wie der
    /// Bildschirm unter der Menüleiste — der Rest wird gescrollt.
    private func applyContentSize(_ size: CGSize, to panel: NSPanel) {
        // Während der Nutzer am Rand zieht, bestimmt er die Größe
        guard size.width > 0, size.height > 0, !panel.inLiveResize else { return }
        let visible = targetScreen()?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxHeight = visible.height - 14
        var size = size
        // Passt der Inhalt nicht auf den Bildschirm: eine Spalte mehr statt
        // scrollen (höchstens drei; nimmt während des Offenseins nie ab,
        // damit sich nichts aufschaukelt)
        if engine.autoFitColumns {
            var columns = engine.freeColumns ?? engine.chosenColumns
            while size.height > maxHeight, columns < 3 {
                columns += 1
                engine.fitColumns = columns
                size = measureContent()
            }
        }
        let target = CGSize(width: engine.dropdownWidth.rounded(.up),
                            height: min(size.height, maxHeight).rounded(.up))
        let current = panel.contentRect(forFrameRect: panel.frame).size
        if abs(current.width - target.width) > 0.5 || abs(current.height - target.height) > 0.5 {
            panel.setContentSize(target)
        }
        updateSizeLimits(panel)
        position(panel)
    }

    private func targetScreen() -> NSScreen? {
        if let detachedTopLeft,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(detachedTopLeft) }) {
            return screen
        }
        return statusItem.button?.window?.screen ?? NSScreen.screens.first
    }

    /// Ziehbare Breite: eine bis drei Spalten. Die Höhe folgt immer dem
    /// Inhalt — eine gezogene Höhe hat Kacheln abgeschnitten.
    private func updateSizeLimits(_ panel: NSPanel) {
        let range = engine.widthRange
        let height = panel.contentRect(forFrameRect: panel.frame).height
        panel.contentMinSize = NSSize(width: range.lowerBound, height: height)
        panel.contentMaxSize = NSSize(width: range.upperBound, height: height)
    }

    // MARK: Eck-Griffe

    func gripBegan() {
        gripStartWidth = engine.dropdownWidth
    }

    /// Griff unten links/rechts gezogen: rastet auf die nächste Spaltenzahl.
    /// Angedockt wächst das Fenster nach beiden Seiten (es bleibt unter dem
    /// Symbol zentriert), deshalb zählt der Weg dort doppelt.
    func gripDragged(by dx: CGFloat, fromLeft: Bool) {
        let factor: CGFloat = detachedTopLeft == nil ? 2 : 1
        let raw = gripStartWidth + (fromLeft ? -dx : dx) * factor
        let target = engine.width(forColumns: engine.nearestColumns(forWidth: raw))
        let old = engine.dropdownWidth
        guard abs(target - old) > 0.5 else { return }
        engine.fitColumns = nil
        engine.customWidth = target
        // Losgelöst und links gezogen: rechte Kante bleibt stehen
        if fromLeft, let topLeft = detachedTopLeft {
            detachedTopLeft = NSPoint(x: topLeft.x - (target - old), y: topLeft.y)
        }
        if let panel { applyContentSize(measureContent(), to: panel) }
    }

    // MARK: Verschieben, Größe, Andocken

    /// Der Griff im Kopf hat das Fenster verschoben: dort lassen.
    func panelWasMoved() {
        guard let panel else { return }
        detachedTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        // Losgelöst schließt es nicht mehr beim Klick daneben
        if isOpen { startMonitors() }
    }

    /// Doppelklick auf den Griff: wieder unter dem Menüleisten-Symbol.
    func redock() {
        detachedTopLeft = nil
        guard let panel else { return }
        position(panel)
        if isOpen { startMonitors() }
    }

    /// Einstellungen → Fenster → zurücksetzen: Breite, Höhe und Position automatisch.
    func resetWindowGeometry() {
        engine.customWidth = nil
        engine.fitColumns = nil
        detachedTopLeft = nil
        guard let panel else { return }
        applyContentSize(measureContent(), to: panel)
    }

    /// Unter dem Menüleisten-Eintrag ausrichten, am Bildschirmrand begrenzt.
    /// Ist der Eintrag nicht sichtbar (volle Menüleiste, zweite Instanz),
    /// klappt das Fenster oben rechts auf statt irgendwo.
    private func position(_ panel: NSPanel) {
        let screen = targetScreen()
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        var x = visible.maxX - size.width - 8
        var y = visible.maxY - size.height - 6

        if let detachedTopLeft {
            // Losgelöst: obere linke Ecke bleibt, wo sie hingezogen wurde
            x = detachedTopLeft.x
            y = min(detachedTopLeft.y, visible.maxY) - size.height
        } else if let button = statusItem.button, let buttonWindow = button.window {
            let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            if anchor.width > 0, screen?.frame.intersects(anchor) ?? false {
                x = anchor.midX - size.width / 2
                y = anchor.minY - size.height - 6
            }
        }

        x = min(max(x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
        // Oben nie über die Menüleiste, unten nie unter das Dock
        y = min(y, visible.maxY - size.height)
        y = max(y, visible.minY + 8)
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    // MARK: Schließen bei Klick daneben

    private func startMonitors() {
        stopMonitors()
        // Losgelöste Fenster bleiben offen, bis man sie über das Symbol oder
        // Escape schließt — man hat sie ja bewusst dorthin gestellt
        if detachedTopLeft == nil {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.close() }
            }
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

// MARK: - Größe am Rand ziehen

extension MenuBarController: NSWindowDelegate {
    /// Live mitziehen: Die Breite geht sofort an den Inhalt (Spaltenzahl).
    func windowDidResize(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, panel.inLiveResize else { return }
        let width = panel.contentRect(forFrameRect: panel.frame).width
        if abs((engine.customWidth ?? 0) - width) > 0.5 {
            engine.fitColumns = nil
            engine.customWidth = width
        }
    }

    /// Losgelassen: auf die nächste ganze Spaltenzahl einrasten.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else { return }
        let content = panel.contentRect(forFrameRect: panel.frame)
        engine.customWidth = engine.width(forColumns: engine.nearestColumns(forWidth: content.width))
        if detachedTopLeft != nil {
            detachedTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        }
        applyContentSize(measureContent(), to: panel)
    }
}

// MARK: - Fensterinhalt

/// Dropdown im ScrollView: Passt er nicht auf den Bildschirm, wird gescrollt
/// statt oben über den Rand hinauszuragen. Die Höhe des Inhalts wird im
/// ScrollView gemessen — dort hängt sie nicht von der Fenstergröße ab — und
/// an den Controller gemeldet, der das Fenster danach ausrichtet.
struct MenuPanelContent: View {
    let engine: StatsEngine
    let onContentSize: (CGSize) -> Void

    var body: some View {
        ScrollView(.vertical) {
            DropdownView(engine: engine)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    onContentSize(size)
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        // Falls doch gescrollt werden muss: Leiste kurz zeigen
        .scrollIndicatorsFlash(onAppear: true)
        .overlay(alignment: .bottomLeading) { ResizeGrip(fromLeft: true) }
        .overlay(alignment: .bottomTrailing) { ResizeGrip(fromLeft: false) }
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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "floosh"
            w.isReleasedWhenClosed = false
            w.toolbarStyle = .preference
            // Breite ist von der Tab-Leiste diktiert: Passen die Tabs nicht
            // nebeneinander, klappt macOS sie in ein »-Überlaufmenü — mit
            // acht Tabs (Island, Menüleiste) brauchen gut 760 pt.
            let host = NSHostingView(rootView:
                SettingsWindow(engine: engine, fixedHeight: false).frame(width: 780))
            // `.minSize`, damit das Fenster kleiner sein darf als der längste
            // Tab — sonst reicht es über den Bildschirmrand hinaus. Die
            // Höhe setzt `place(_:)` beim Öffnen.
            host.sizingOptions = [.minSize]
            w.contentView = host
            w.setContentSize(NSSize(width: 780, height: 600))
            window = w
        }
        if let window { place(window) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// So hoch wie der Bildschirm (die Tabs sind lang — so muss kaum
    /// gescrollt werden) und direkt neben dem offenen Dropdown, links davon,
    /// wenn dort Platz ist, sonst rechts. Ohne Dropdown: mittig.
    private func place(_ window: NSWindow) {
        let menu = MenuBarController.shared
        let anchor = menu?.isOpen == true ? menu?.panelFrame : nil
        let screen = anchor.flatMap { a in NSScreen.screens.first { $0.frame.intersects(a) } }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        var frame = window.frame
        let titleBar = frame.height - window.contentRect(forFrameRect: frame).height
        frame.size.height = min(visible.height - 12, 1400 + titleBar)
        frame.origin.y = visible.maxY - frame.height - 6

        let gap: CGFloat = 10
        if let anchor {
            if anchor.minX - gap - frame.width >= visible.minX + 8 {
                frame.origin.x = anchor.minX - gap - frame.width
            } else if anchor.maxX + gap + frame.width <= visible.maxX - 8 {
                frame.origin.x = anchor.maxX + gap
            } else {
                // Passt weder links noch rechts: an den freieren Rand
                let leftRoom = anchor.minX - visible.minX
                let rightRoom = visible.maxX - anchor.maxX
                frame.origin.x = leftRoom > rightRoom ? visible.minX + 8 : visible.maxX - frame.width - 8
            }
        } else {
            frame.origin.x = visible.midX - frame.width / 2
        }
        window.setFrame(frame, display: true)
    }
}
