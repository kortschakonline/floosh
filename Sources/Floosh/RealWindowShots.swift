import SwiftUI
import AppKit

/// README-Screenshots aus echten Fenstern: Dropdown (auf dunklem Backdrop)
/// und Einstellungsfenster, mit echtem Liquid Glass.
///
/// Die App kann eigene Fenster unter macOS 26 nicht mehr selbst abbilden
/// (`CGWindowListCreateImage*` entfernt, ScreenCaptureKit verlangt
/// Bildschirmaufnahme-Rechte). Darum zeigt `--shoot` die Szenen nur an und
/// meldet Region bzw. Fenster-ID auf stdout — ein externes `screencapture`
/// macht die Aufnahmen:
///
///   DROPDOWN <x>,<y>,<w>,<h>   (Region, Ursprung oben links, ~10 s sichtbar)
///   SETTINGS <windowNumber>    (für `screencapture -o -l<id>`, ~10 s sichtbar)
@MainActor
enum RealWindowShots {

    static func run(engine: StatsEngine) async {
        // `--shoot settings [display|measurement|fans|general]`: nur das
        // Einstellungsfenster (optional mit Start-Tab), ohne Warmlaufphase
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--shoot"),
           args.count > idx + 1, args[idx + 1] == "settings" {
            let tab = args.count > idx + 2 ? SettingsTab(rawValue: args[idx + 2]) : nil
            await presentSettings(engine: engine, tab: tab ?? .display)
            return
        }

        // Kompaktes Diagramm-Fenster, damit die Verlaufslinien nach der
        // Warmlaufphase die volle Breite füllen
        engine.chartWindow = 30
        engine.showPeaks = true
        engine.showDevices = true
        try? await Task.sleep(for: .seconds(34))

        await presentDropdown(engine: engine)
        await presentSettings(engine: engine)
    }

    // MARK: Dropdown

    private static func presentDropdown(engine: StatsEngine) async {
        // Panel: das Dropdown mit der dunklen Glas-Rückwand des Menü-Fensters
        let panel = makeWindow(size: NSSize(width: engine.dropdownWidth, height: 1))
        panel.contentView = NSHostingView(rootView:
            DropdownView(engine: engine)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
                .environment(\.colorScheme, .dark)
        )
        panel.setContentSize(panel.contentView!.fittingSize)

        // Backdrop: dunkle Fläche hinter dem Panel, durch die das Glas schimmert
        let margin: CGFloat = 30
        let backdrop = makeWindow(size: NSSize(width: panel.frame.width + 2 * margin,
                                               height: panel.frame.height + 2 * margin))
        backdrop.contentView = NSHostingView(rootView:
            LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.16),
                                    Color(red: 0.05, green: 0.05, blue: 0.09)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        )

        center(backdrop)
        panel.setFrameOrigin(NSPoint(x: backdrop.frame.minX + margin,
                                     y: backdrop.frame.minY + margin))
        backdrop.orderFront(nil)
        panel.orderFront(nil)

        announceRegion("DROPDOWN", frame: backdrop.frame)
        try? await Task.sleep(for: .seconds(10))
        panel.orderOut(nil)
        backdrop.orderOut(nil)
    }

    // MARK: Einstellungen

    private static func presentSettings(engine: StatsEngine, tab: SettingsTab = .display) async {
        let window = NSWindow(contentRect: .zero,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "floosh"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.level = .statusBar
        // Wie das echte Settings-Fenster: Tab-Leiste zentriert statt Overflow
        window.toolbarStyle = .preference
        // Etwas breiter als die 420-pt-Form, sonst rutscht die Tab-Leiste
        // unter die Fensterknöpfe (NSHostingView zieht das Fenster sonst
        // wieder auf die Idealbreite zusammen)
        window.contentView = NSHostingView(rootView:
            SettingsWindow(engine: engine, initialTab: tab).frame(width: 520))
        window.setContentSize(window.contentView!.fittingSize)
        center(window)
        window.orderFront(nil)

        print("SETTINGS \(window.windowNumber)")
        flushStdout()
        try? await Task.sleep(for: .seconds(10))
        window.orderOut(nil)
    }

    // MARK: Helfer

    private static func makeWindow(size: NSSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.level = .statusBar
        return w
    }

    /// Auf dem Primärbildschirm zentrieren — derselbe, auf den sich
    /// `announceRegion` bezieht (bei mehreren Displays sonst falsche Region).
    private static func center(_ window: NSWindow) {
        guard let screen = NSScreen.screens.first else { return }
        let f = window.frame
        window.setFrameOrigin(NSPoint(x: (screen.frame.midX - f.width / 2).rounded(),
                                      y: (screen.frame.midY - f.height / 2).rounded()))
    }

    /// Meldet eine Fenster-Region in `screencapture -R`-Koordinaten
    /// (Punkte, Ursprung oben links des Hauptbildschirms).
    private static func announceRegion(_ label: String, frame: NSRect) {
        guard let screen = NSScreen.screens.first else { return }
        let topLeftY = screen.frame.maxY - frame.maxY
        print("\(label) \(Int(frame.minX)),\(Int(topLeftY)),\(Int(frame.width)),\(Int(frame.height))")
        flushStdout()
    }

    private static func flushStdout() {
        fflush(stdout)
    }
}
