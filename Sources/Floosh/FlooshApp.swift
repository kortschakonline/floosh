import SwiftUI
import AppKit

@main
struct FlooshApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var engine = StatsEngine()

    init() {
        DebugSnapshot.runIfRequested(engine: engine)
        if !DebugSnapshot.isActive {
            UpdateChecker.shared.startLoop()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            DropdownView(engine: engine)
        } label: {
            MenuBarLabel(engine: engine)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsWindow(engine: engine)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reine Menüleisten-App: kein Dock-Icon, auch beim Start über `swift run`
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Manuelle Lüftersteuerung nicht verwaist zurücklassen
        MainActor.assumeIsolated {
            FanService.shared.relinquishOnQuit()
        }
    }
}
