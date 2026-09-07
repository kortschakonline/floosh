import SwiftUI
import AppKit

@main
struct FlooshApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let engine = StatsEngine.shared

    init() {
        DebugSnapshot.runIfRequested(engine: engine)
        if !DebugSnapshot.isActive {
            UpdateChecker.shared.startLoop()
        }
        if !DebugSnapshot.isActive, !DebugSnapshot.shootRequested {
            // Fenster erst anlegen, wenn AppKit den Start abgeschlossen hat
            let engine = engine
            Task { @MainActor in DesktopPanelController.shared.attach(engine: engine) }
        }
    }

    /// Nur noch das Einstellungsfenster als Szene — die Menüleiste läuft über
    /// `MenuBarController` (eigener `NSStatusItem`, siehe MenuBarWindow.swift).
    var body: some Scene {
        Settings {
            SettingsWindow(engine: engine)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reine Menüleisten-App: kein Dock-Icon, auch beim Start über `swift run`
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            guard !DebugSnapshot.isActive, !DebugSnapshot.shootRequested else { return }
            MenuBarController.start(engine: .shared)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Manuelle Lüftersteuerung nicht verwaist zurücklassen
        MainActor.assumeIsolated {
            FanService.shared.relinquishOnQuit()
            FileShelf.shared.clearOnQuitIfNeeded()
            // Sonst bliebe die Energie-Zusicherung bis zum Abmelden stehen
            KeepAwake.shared.stop()
            CleanScreen.shared.stop()
        }
    }
}
