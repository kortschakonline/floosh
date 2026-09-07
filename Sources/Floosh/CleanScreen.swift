import SwiftUI
import AppKit
import Observation

/// Bildschirm zum Reinigen abdunkeln: schwarze Fenster über allen
/// Bildschirmen, die Klicks und Tasten schlucken — man kann mit dem Tuch
/// über Tastatur, Trackpad und Display fahren, ohne etwas auszulösen.
///
/// Ein Sicherheitsnetz gehört dazu: Der Modus beendet sich nach Ablauf der
/// eingestellten Zeit von selbst, zusätzlich zu Escape. Ein Vollbild, das
/// nur auf eine bestimmte Taste hört, ist sonst eine Falle.
///
/// Grenze: Systemweite Tastenkürzel (⌘-Tab, Lautstärke, Exposé) fängt macOS
/// vor jeder App ab — die bleiben aktiv. Alles andere landet bei uns.
@MainActor
@Observable
final class CleanScreen {

    static let shared = CleanScreen()

    private(set) var isActive = false
    /// Verbleibende Sekunden, während der Modus läuft.
    private(set) var remaining = 0

    /// Wie lange abgedunkelt wird (Sekunden).
    var seconds: Int {
        didSet { defaults.set(seconds, forKey: "clean.seconds") }
    }

    static let choices = [15, 30, 60, 120]

    private var windows: [NSWindow] = []
    private var keyMonitor: Any?
    private var ticker: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    private init() {
        let saved = defaults.object(forKey: "clean.seconds") as? Int
        seconds = saved.map { Self.choices.contains($0) ? $0 : 30 } ?? 30
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        remaining = seconds

        for screen in NSScreen.screens {
            // Eigene Klasse, weil ein rahmenloses Fenster sonst nicht
            // Key-Window werden kann — und ohne Key-Window bekommt der
            // Tastatur-Monitor kein Escape. Der Modus wäre eine Falle.
            let window = CleanWindow(contentRect: screen.frame,
                                     styleMask: [.borderless],
                                     backing: .buffered, defer: false)
            window.level = .screenSaver
            window.backgroundColor = .black
            window.isOpaque = true
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            // Nur auf dem Bildschirm mit der Menüleiste steht der Countdown —
            // sonst leuchten auf jedem Display Zahlen.
            let isMain = screen == NSScreen.screens.first
            window.contentView = NSHostingView(rootView: CleanScreenOverlay(clean: self, showsInfo: isMain))
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)

        // Escape beendet sofort. Jede andere Taste wird geschluckt.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in self?.stop() }
            }
            return nil
        }

        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.isActive else { return }
                self.remaining -= 1
                if self.remaining <= 0 {
                    self.stop()
                    return
                }
            }
        }
    }

    func stop() {
        guard isActive else { return }
        ticker?.cancel()
        ticker = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        isActive = false
        remaining = 0
    }
}

/// Rahmenlos, aber trotzdem tastaturfähig.
private final class CleanWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Was auf dem abgedunkelten Bildschirm steht: Countdown und der Hinweis,
/// wie man wieder herauskommt.
private struct CleanScreenOverlay: View {
    @Bindable var clean: CleanScreen
    let showsInfo: Bool

    var body: some View {
        ZStack {
            Color.black
            if showsInfo {
                VStack(spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 34, weight: .light))
                    Text("\(clean.remaining)")
                        .font(.system(size: 64, weight: .thin, design: .rounded))
                        .monospacedDigit()
                    Text("Eingaben sind gesperrt — jetzt putzen.")
                        .font(.callout)
                    Text("Escape beendet sofort")
                        .font(.caption)
                        .opacity(0.6)
                }
                // Dunkel genug, dass es beim Reinigen nicht blendet, hell
                // genug, um es zu finden
                .foregroundStyle(.white.opacity(0.35))
            }
        }
        .ignoresSafeArea()
    }
}
