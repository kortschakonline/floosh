import SwiftUI
import AppKit

/// Entwickler-Hook: `floosh --snapshot <ordner>` rendert das Dropdown und die
/// Menüleisten-Label-Varianten als PNGs und beendet die App — für visuelle
/// Checks ohne HID-Klicks (AppleScript kann MenuBarExtra nicht öffnen).
@MainActor
enum DebugSnapshot {
    /// Im Snapshot-Modus ersetzen die Karten ihr Liquid Glass durch eine
    /// einfache Fläche — `ImageRenderer` lässt glassEffect-Inhalte sonst leer.
    static var isActive: Bool { requestedDirectory != nil }

    static var requestedDirectory: String? {
        guard let idx = CommandLine.arguments.firstIndex(of: "--snapshot"),
              CommandLine.arguments.count > idx + 1 else { return nil }
        return CommandLine.arguments[idx + 1]
    }

    static func runIfRequested(engine: StatsEngine) {
        if let dir = requestedDirectory {
            Task { @MainActor in
                // Sampler zwei Runden laufen lassen, damit echte Werte da sind
                try? await Task.sleep(for: .seconds(3))
                write(to: dir, engine: engine)
                NSApp.terminate(nil)
            }
        }
        if shootRequested {
            Task { @MainActor in
                await RealWindowShots.run(engine: engine)
                NSApp.terminate(nil)
            }
        }
    }

    /// `floosh --shoot`: zeigt Dropdown und Einstellungen nacheinander in
    /// echten Fenstern (echtes Liquid Glass) und meldet Region/Fenster-ID auf
    /// stdout, damit ein externes `screencapture` die README-Screenshots
    /// aufnehmen kann (siehe `RealWindowShots`).
    static var shootRequested: Bool {
        CommandLine.arguments.contains("--shoot")
    }

    private static func write(to dir: String, engine: StatsEngine) {
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        for scheme in [ColorScheme.dark, ColorScheme.light] {
            let name = scheme == .dark ? "dropdown-dark" : "dropdown-light"
            let view = DropdownView(engine: engine)
                .frame(width: 340)
                .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.92))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let img = renderer.nsImage {
                save(img, to: url.appendingPathComponent("\(name).png"))
            }
        }

        for style in [MenuSystemStyle.number, .bar] {
            let img = LabelImageRenderer.render(
                group: engine.selectedGroup,
                labelStyle: engine.labelStyle,
                iconStyle: engine.iconStyle,
                singleLine: "3,1 MB/s",
                readLine: "L 16,0K",
                writeLine: "S 2,9M",
                systemStyle: style,
                cpuUsage: engine.system.cpuUsage,
                gpuUsage: engine.system.gpuUsage
            )
            save(img, to: url.appendingPathComponent("label-\(style.rawValue).png"))
        }
    }

    private static func save(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
