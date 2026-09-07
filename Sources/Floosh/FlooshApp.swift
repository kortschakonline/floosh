import SwiftUI
import AppKit

@main
struct FlooshApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let engine = StatsEngine.shared

    init() {
        HelperRepair.runIfRequested()
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
            // Erzeugt den Wächter; er startet seine Schleife nur, wenn der
            // Fangstreifen eingeschaltet ist.
            _ = DragCatcher.shared
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

/// `floosh --repair-helper` meldet den Lüfter-Helper ab und neu an und
/// beendet sich dann. Gedacht für den Fall, dass die Registrierung nach
/// einem Update nicht mehr zur Binary passt und die Oberfläche deshalb gar
/// nicht erst erreichbar ist — und um den Zustand ohne Klicken zu prüfen.
@MainActor
enum HelperRepair {
    static func runIfRequested() {
        let args = CommandLine.arguments
        let wantsPing = args.contains("--helper-ping")
        guard args.contains("--repair-helper") || args.contains("--helper-status") || wantsPing else { return }
        let fans = FanService.shared
        print("Bundle:  \(Bundle.main.bundlePath)")
        print("Build:   \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
        print("Zustand: \(fans.helperState)")
        if args.contains("--repair-helper") {
            fans.reregisterHelper()
            // Die Neuregistrierung läuft mit Pausen — hier darauf warten.
            Task { @MainActor in
                while fans.isReregistering { try? await Task.sleep(for: .milliseconds(200)) }
                print("nachher: \(fans.helperState)")
                if let error = fans.lastError { print("Fehler:  \(error)") }
                if wantsPing {
                    fans.pingHelperForDiagnostics { line in print(line); exit(0) }
                } else {
                    exit(0)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                print("Abbruch: Neuregistrierung dauert zu lange")
                exit(1)
            }
            RunLoop.main.run()
        }
        guard wantsPing else { exit(0) }
        // Echter XPC-Kontakt: Antwortet der Helper, läuft die Steuerung.
        fans.pingHelperForDiagnostics { line in
            print(line)
            exit(0)
        }
        // Antwortet niemand, nicht ewig hängen bleiben
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            print("Antwort: keine (Zeitüberschreitung)")
            exit(1)
        }
        RunLoop.main.run()
    }
}
