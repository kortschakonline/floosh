import SwiftUI
import AppKit

@main
struct FlooshApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var engine = StatsEngine()

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
}

/// Das floosh-Logo: Stoppuhr, durch die ein Blitz fährt.
struct FlooshLogo: View {
    var size: CGFloat = 16
    var tint: Color = .yellow

    var body: some View {
        ZStack {
            Image(systemName: "stopwatch")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary)
            Image(systemName: "bolt.fill")
                .font(.system(size: size * 0.62, weight: .bold))
                .foregroundStyle(tint)
                .rotationEffect(.degrees(12))
                .offset(y: size * 0.08)
                .shadow(color: tint.opacity(0.7), radius: size * 0.16)
        }
    }
}
