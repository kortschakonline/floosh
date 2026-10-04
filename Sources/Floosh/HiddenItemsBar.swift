import SwiftUI
import AppKit

/// Stufe 2 des Organizers: eine schwebende Leiste direkt unter der Menüleiste
/// mit den versteckten Symbolen. Klick auf ein Symbol „drückt" das echte
/// Symbol (Bedienungshilfen) — sein Menü öffnet sich wie gewohnt.
///
/// So bleibt die Menüleiste aufgeräumt, und auf MacBooks mit Notch
/// verschwindet nichts mehr hinter der Notch.
@MainActor
final class HiddenItemsBar {
    static let shared = HiddenItemsBar()

    private var panel: NSPanel?
    private var host: NSHostingView<HiddenItemsBarView>?
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var includeAlways = false

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(includingAlwaysHidden: Bool) {
        if isVisible, includeAlways == includingAlwaysHidden {
            close()
        } else {
            show(includingAlwaysHidden: includingAlwaysHidden)
        }
    }

    func show(includingAlwaysHidden: Bool) {
        includeAlways = includingAlwaysHidden
        let panel = panel ?? makePanel()
        host?.rootView = HiddenItemsBarView(items: .shared, includeAlways: includingAlwaysHidden)
        place(panel)
        panel.orderFrontRegardless()
        startMonitors()
        Task {
            await MenuBarItems.shared.refreshIfNeeded()
            // Nach dem Einlesen ändert sich die Breite
            if let panel = self.panel { self.place(panel) }
        }
    }

    func close() {
        panel?.orderOut(nil)
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        outsideMonitor = nil
        keyMonitor = nil
    }

    /// Klick auf ein Symbol in der Leiste: Leiste zu, echtes Symbol drücken.
    func activate(_ item: MenuBarItems.Item) {
        close()
        Task {
            // Kurz warten, bis die Leiste weg ist — sonst schließt der Klick
            // daneben das gerade geöffnete Menü gleich wieder
            try? await Task.sleep(for: .milliseconds(80))
            MenuBarItems.shared.press(item)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: HiddenItemsBarView(items: .shared, includeAlways: false))
        host.sizingOptions = []
        panel.contentView = host
        self.host = host
        self.panel = panel
        return panel
    }

    /// Unter dem Pfeil, rechtsbündig; am Bildschirmrand begrenzt.
    private func place(_ panel: NSPanel) {
        // Eigene Mess-View: Die Hosting-View im Fenster meldet ohne
        // Größenoptionen keine Idealgröße (sonst wäre die Leiste 0 × 0)
        let size = NSHostingView(rootView: HiddenItemsBarView(items: .shared, includeAlways: includeAlways)).fittingSize
        let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let anchor = MenuBarOrganizer.shared.toggleFrame()
        var x = (anchor?.maxX ?? visible.maxX - 8) - size.width + 6
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = visible.maxY - size.height - 4
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
    }

    private func startMonitors() {
        guard outsideMonitor == nil else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in
                // Klick auf den Pfeil selbst schaltet über toggle() um
                if MenuBarOrganizer.shared.toggleFrame()?.contains(NSEvent.mouseLocation) == true { return }
                HiddenItemsBar.shared.close()
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 {
                Task { @MainActor in HiddenItemsBar.shared.close() }
                return nil
            }
            return event
        }
    }
}

/// Inhalt der Leiste: die Symbolbilder als Knöpfe.
struct HiddenItemsBarView: View {
    @Bindable var items: MenuBarItems
    let includeAlways: Bool

    var body: some View {
        let shown = items.items.filter { includeAlways || !$0.isAlwaysHidden }
        HStack(spacing: 2) {
            if shown.isEmpty {
                Text(placeholder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            } else {
                ForEach(shown) { item in
                    MenuBarItemButton(item: item) {
                        HiddenItemsBar.shared.activate(item)
                    }
                }
            }
            if items.isScanning {
                ProgressView().controlSize(.small).padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
        .background(.regularMaterial, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        }
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private var placeholder: String {
        if !items.hasAllPermissions { return "floosh braucht Bedienungshilfen und Bildschirmaufnahme" }
        if items.isScanning { return "Symbole werden eingelesen …" }
        return "Keine versteckten Symbole"
    }
}

/// Ein Symbol als Knopf — zeigt das aufgenommene Bild, sonst den App-Namen.
struct MenuBarItemButton: View {
    let item: MenuBarItems.Item
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let image = item.image {
                    Image(nsImage: image)
                        .interpolation(.high)
                } else {
                    Text(item.label)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                }
            }
            .frame(minWidth: 26, minHeight: 24)
            .padding(.horizontal, 2)
            .background(.white.opacity(hovering ? 0.16 : 0), in: .rect(cornerRadius: 6))
            .opacity(item.isAlwaysHidden ? 0.75 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(item.label) — \(item.appName)")
        .accessibilityLabel("\(item.label), \(item.appName)")
    }
}
