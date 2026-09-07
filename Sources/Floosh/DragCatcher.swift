import SwiftUI
import AppKit
import Observation

// MARK: - Erkennung

/// Erkennt, dass irgendwo im System gerade Dateien gezogen werden, und
/// blendet dafür einen Fangstreifen am Bildschirmrand ein.
///
/// Warum überhaupt: Auf das Menüleisten-Symbol zu zielen ist beim Ziehen
/// unangenehm — am oberen Bildschirmrand greift zuerst macOS zu (Mission
/// Control), und das Desktop-Panel liegt hinter allen Fenstern. Der Streifen
/// kommt stattdessen zum Zeiger.
///
/// Wie ohne Sonderrechte: Kein Event-Tap und kein globaler Monitor (die
/// brauchen Bedienungshilfen bzw. Eingabeüberwachung), sondern zwei reine
/// Abfragen im Messtakt — ob die linke Maustaste unten ist
/// (`NSEvent.pressedMouseButtons`) und ob auf dem Drag-Pasteboard Datei-URLs
/// liegen. Beides ist frei zugänglich.
@MainActor
@Observable
final class DragCatcher {

    static let shared = DragCatcher()

    enum Edge: String, CaseIterable, Identifiable {
        case right, left, top, bottom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .right: "Rechts"
            case .left: "Links"
            case .top: "Oben"
            case .bottom: "Unten"
            }
        }
    }

    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "catcher.enabled")
            if enabled { start() } else { stop() }
        }
    }
    var edge: Edge {
        didSet { defaults.set(edge.rawValue, forKey: "catcher.edge") }
    }

    /// Läuft gerade ein Datei-Drag?
    private(set) var isDragging = false
    /// Kurze Rückmeldung nach dem Ablegen.
    private(set) var accepted = 0

    private let defaults = UserDefaults.standard
    private var loop: Task<Void, Never>?
    /// Stand des Drag-Pasteboards beim letzten Loslassen — daran erkennt man,
    /// ob der aktuelle Inhalt zu einem *neuen* Drag gehört oder nur der Rest
    /// vom letzten ist.
    private var settledChangeCount = 0
    private var hideTask: Task<Void, Never>?

    private init() {
        enabled = defaults.object(forKey: "catcher.enabled") as? Bool ?? false
        edge = Edge(rawValue: defaults.string(forKey: "catcher.edge") ?? "") ?? .right
        settledChangeCount = NSPasteboard(name: .drag).changeCount
        if enabled { start() }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                self?.poll()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        setDragging(false)
    }

    private func poll() {
        let mouseDown = NSEvent.pressedMouseButtons & 1 != 0
        let pasteboard = NSPasteboard(name: .drag)

        guard mouseDown else {
            // Losgelassen: aktuellen Stand merken, damit derselbe Inhalt
            // nicht beim nächsten Mausklick erneut als Drag zählt.
            if isDragging || settledChangeCount != pasteboard.changeCount {
                settledChangeCount = pasteboard.changeCount
            }
            setDragging(false)
            return
        }

        // Maustaste unten: nur ein *frischer* Pasteboard-Stand mit Datei-URLs
        // ist wirklich ein laufender Drag.
        guard pasteboard.changeCount != settledChangeCount else { return }
        let hasFiles = pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true])
        setDragging(hasFiles)
    }

    private func setDragging(_ value: Bool) {
        guard isDragging != value else { return }
        isDragging = value
        if value {
            hideTask?.cancel()
            DragCatcherWindow.shared.show(edge: edge)
        } else {
            // Kurz stehen lassen: Der Drop wird erst nach dem Loslassen
            // zugestellt — verschwindet der Streifen sofort, geht er verloren.
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, self?.isDragging == false else { return }
                DragCatcherWindow.shared.hide()
            }
        }
    }

    /// Vom Streifen aufgerufen, wenn Dateien abgelegt wurden.
    @discardableResult
    func accept(_ urls: [URL]) -> Bool {
        let added = FileShelf.shared.add(urls)
        accepted = added
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.accepted = 0
            DragCatcherWindow.shared.hide()
        }
        return added > 0
    }
}

// MARK: - Fenster

/// Das schwebende Fenster mit dem Fangstreifen. Es erscheint auf dem
/// Bildschirm, auf dem der Zeiger gerade ist — der Streifen soll dort sein,
/// wo gezogen wird, nicht dort, wo die App zufällig wohnt.
@MainActor
final class DragCatcherWindow {

    static let shared = DragCatcherWindow()

    private var panel: NSPanel?

    private static let size = CGSize(width: 210, height: 132)
    private static let margin: CGFloat = 12

    func show(edge: DragCatcher.Edge) {
        let panel = panel ?? make()
        position(panel, edge: edge)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Für den Dev-Hook `--shoot catcher`.
    var frame: NSRect? { panel?.frame }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // Über normalen Fenstern, aber unter Menüs — der Streifen soll das
        // Menüleisten-Fenster nicht verdecken.
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovable = false
        p.animationBehavior = .utilityWindow
        p.contentViewController = NSHostingController(rootView: DragCatcherView())
        panel = p
        return p
    }

    /// An die gewählte Kante des Bildschirms unter dem Mauszeiger.
    private func position(_ panel: NSPanel, edge: DragCatcher.Edge) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { return }
        let size = Self.size
        let m = Self.margin
        let origin: CGPoint
        switch edge {
        case .right:
            origin = CGPoint(x: area.maxX - size.width - m,
                             y: min(max(mouse.y - size.height / 2, area.minY + m),
                                    area.maxY - size.height - m))
        case .left:
            origin = CGPoint(x: area.minX + m,
                             y: min(max(mouse.y - size.height / 2, area.minY + m),
                                    area.maxY - size.height - m))
        case .top:
            origin = CGPoint(x: min(max(mouse.x - size.width / 2, area.minX + m),
                                    area.maxX - size.width - m),
                             y: area.maxY - size.height - m)
        case .bottom:
            origin = CGPoint(x: min(max(mouse.x - size.width / 2, area.minX + m),
                                    area.maxX - size.width - m),
                             y: area.minY + m)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}

// MARK: - Inhalt

/// Der Streifen selbst: eine Glas-Fläche, die Dateien annimmt.
private struct DragCatcherView: View {
    @Bindable private var catcher = DragCatcher.shared
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: catcher.accepted > 0 ? "checkmark.circle.fill" : "tray.and.arrow.down.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(catcher.accepted > 0 ? .green : (targeted ? Color.accentColor : .secondary))

            Text(label)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(targeted ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: targeted ? [] : [5, 4]))
                .foregroundStyle(targeted ? Color.accentColor : .secondary.opacity(0.5))
                .padding(5)
        }
        .cardGlass(tint: targeted ? Color.accentColor.opacity(0.16) : nil, cornerRadius: 20)
        .dropDestination(for: URL.self) { urls, _ in
            catcher.accept(urls)
        } isTargeted: { targeted = $0 }
    }

    private var label: String {
        if catcher.accepted > 0 {
            return catcher.accepted == 1 ? "1 Datei in der Ablage" : "\(catcher.accepted) Dateien in der Ablage"
        }
        return targeted ? "Loslassen" : "Hier ablegen"
    }
}
