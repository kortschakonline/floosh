import AppKit
import ApplicationServices
import ScreenCaptureKit
import Observation

/// Menüleisten-Organizer, Stufe 2: die versteckten Symbole anderer Apps finden,
/// ihr Aussehen aufnehmen und sie auf Klick „drücken".
///
/// - **Finden**: Unter macOS 27 sind Menüleisten-Symbole keine eigenen Fenster
///   mehr. Positionen gibt es nur über die Bedienungshilfen:
///   `AXExtrasMenuBar` jeder laufenden App liefert ihre Symbole mit Lage und
///   der Aktion `AXPress`.
/// - **Drücken**: `AXPress` öffnet das Menü bzw. Popover eines Symbols — auch
///   wenn es gerade versteckt ist. Keine Mausbewegung nötig.
/// - **Aussehen**: Versteckte Symbole werden nicht gezeichnet. floosh klappt
///   deshalb kurz aus, nimmt die Menüleiste auf (ScreenCaptureKit), schneidet
///   jedes Symbol aus und merkt sich die Bilder.
///
/// Rechte: „Bedienungshilfen" (Finden/Drücken) und „Bildschirmaufnahme" (Bilder).
@MainActor
@Observable
final class MenuBarItems {
    static let shared = MenuBarItems()

    struct Item: Identifiable {
        /// Stabil über Neuaufnahmen hinweg: App + Beschreibung + Reihenfolge.
        let id: String
        let appName: String
        let label: String
        let isAlwaysHidden: Bool
        var image: NSImage?
        let element: AXUIElement
        /// Breite des Originalsymbols in Punkten (für die Darstellung).
        let width: CGFloat
    }

    private(set) var items: [Item] = []
    private(set) var lastScan: Date?
    private(set) var isScanning = false
    private(set) var lastError: String?

    // MARK: Rechte

    var hasAccessibility: Bool { AXIsProcessTrusted() }
    var hasScreenCapture: Bool { CGPreflightScreenCaptureAccess() }
    var hasAllPermissions: Bool { hasAccessibility && hasScreenCapture }

    /// Fragt fehlende Rechte an (macOS zeigt dafür seine eigenen Dialoge).
    func requestPermissions() {
        if !hasAccessibility {
            // Wert von kAXTrustedCheckOptionPrompt (die Konstante ist in Swift 6
            // als veränderlicher globaler Zustand markiert)
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        if !hasScreenCapture {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    func openPrivacySettings(_ pane: String) {
        // pane: "Privacy_Accessibility" bzw. "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Einlesen

    /// Neu einlesen, wenn noch nichts da ist oder die letzte Aufnahme älter ist.
    func refreshIfNeeded(maxAge: TimeInterval = 120) async {
        if let lastScan, Date().timeIntervalSince(lastScan) < maxAge, !items.isEmpty { return }
        await refresh()
    }

    /// Klappt alles kurz aus, liest Lage und Aussehen der versteckten Symbole
    /// und stellt den vorherigen Zustand wieder her.
    func refresh() async {
        guard !isScanning else { return }
        guard hasAccessibility else { lastError = "Bedienungshilfen-Recht fehlt"; return }
        let organizer = MenuBarOrganizer.shared
        guard organizer.isRunning else { return }
        isScanning = true
        defer { isScanning = false }

        let wasExpanded = organizer.isExpanded
        let wasAlways = organizer.showsAlwaysHidden
        organizer.setExpandedQuietly(true, always: true)
        // macOS braucht einen Moment, bis die Symbole neu gezeichnet sind
        try? await Task.sleep(for: .milliseconds(450))

        let found = scan()
        let images = hasScreenCapture ? await captureImages(for: found) : [:]
        organizer.setExpandedQuietly(wasExpanded, always: wasAlways)

        items = found.map { entry in
            var item = entry.item
            item.image = images[item.id] ?? items.first(where: { $0.id == item.id })?.image
            return item
        }
        lastScan = Date()
        lastError = nil
    }

    /// Ein Symbol „drücken" — öffnet sein Menü oder Popover.
    func press(_ item: Item) {
        let result = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
        if result != .success {
            lastError = "\(item.label) reagiert nicht (\(result.rawValue))"
        }
    }

    // MARK: Bedienungshilfen

    private struct Found {
        var item: Item
        let frame: CGRect
    }

    /// Alle Symbole im versteckten Bereich (zwischen den Trennern) und im
    /// Bereich „immer versteckt" (links vom zweiten Trenner). Die Trenner
    /// müssen dafür ausgeklappt sein.
    private func scan() -> [Found] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let bounds = ownDividerBounds(pid: ownPID) else { return [] }
        var result: [Found] = []
        var seen: [String: Int] = [:]

        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != ownPID {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            guard let bar: AXUIElement = Self.attribute(axApp, "AXExtrasMenuBar") else { continue }
            let children: [AXUIElement] = Self.attribute(bar, kAXChildrenAttribute) ?? []
            for element in children {
                guard let frame = Self.frame(of: element), frame.width > 0, frame.width < 300 else { continue }
                let mid = frame.midX
                let isAlways: Bool
                if mid < bounds.hiddenStart && mid > bounds.alwaysStart {
                    isAlways = false
                } else if mid < bounds.alwaysStart {
                    isAlways = true
                } else {
                    continue // sichtbarer Bereich
                }
                let description: String = Self.attribute(element, kAXDescriptionAttribute) ?? ""
                let title: String = Self.attribute(element, kAXTitleAttribute) ?? ""
                let name = app.localizedName ?? app.bundleIdentifier ?? "App"
                let base = "\(app.bundleIdentifier ?? name)|\(description)"
                let n = seen[base, default: 0]
                seen[base] = n + 1
                let label = !description.isEmpty ? description : (!title.isEmpty ? title : name)
                result.append(Found(item: Item(id: "\(base)|\(n)", appName: name, label: label,
                                               isAlwaysHidden: isAlways, image: nil,
                                               element: element, width: frame.width),
                                    frame: frame))
            }
        }
        return result.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Lage der eigenen Trenner über die Bedienungshilfen — die Fensterlage
    /// der Status-Knöpfe stimmt unter macOS 27 nicht mit der Menüleiste überein.
    private func ownDividerBounds(pid: pid_t) -> (hiddenStart: CGFloat, alwaysStart: CGFloat)? {
        let axApp = AXUIElementCreateApplication(pid)
        guard let bar: AXUIElement = Self.attribute(axApp, "AXExtrasMenuBar") else { return nil }
        var hidden: CGRect?
        var always: CGRect?
        for element in (Self.attribute(bar, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            let description: String = Self.attribute(element, kAXDescriptionAttribute) ?? ""
            let title: String = Self.attribute(element, kAXTitleAttribute) ?? ""
            let name = description.isEmpty ? title : description
            if name == MenuBarOrganizer.hiddenDividerLabel { hidden = Self.frame(of: element) }
            if name == MenuBarOrganizer.alwaysDividerLabel { always = Self.frame(of: element) }
        }
        guard let hidden, let always, hidden.width < 200, always.width < 200 else { return nil }
        return (hidden.minX, always.minX)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// Lage in globalen Bildschirmkoordinaten (Ursprung oben links).
    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var extent: CFTypeRef?
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &extent) == .success,
              let position, let extent else { return nil }
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(extent as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    // MARK: Aufnahme

    /// Eine Aufnahme des Menüleisten-Streifens, daraus jedes Symbol ausschneiden.
    private func captureImages(for found: [Found]) async -> [String: NSImage] {
        guard !found.isEmpty,
              let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return [:] }
        let scale = screen.backingScaleFactor
        let barHeight = screen.frame.maxY - screen.visibleFrame.maxY

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return [:] }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: 0, y: 0, width: screen.frame.width, height: barHeight)
            config.width = Int(screen.frame.width * scale)
            config.height = Int(barHeight * scale)
            config.showsCursor = false
            let strip = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            var images: [String: NSImage] = [:]
            for entry in found {
                let f = entry.frame
                let crop = CGRect(x: f.minX * scale, y: max(0, f.minY) * scale,
                                  width: f.width * scale, height: min(f.height, barHeight) * scale).integral
                guard let cg = strip.cropping(to: crop) else { continue }
                images[entry.item.id] = NSImage(cgImage: cg, size: NSSize(width: crop.width / scale,
                                                                         height: crop.height / scale))
            }
            return images
        } catch {
            lastError = "Bildschirmaufnahme fehlgeschlagen: \(error.localizedDescription)"
            return [:]
        }
    }
}
