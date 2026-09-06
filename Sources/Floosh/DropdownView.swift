import SwiftUI

/// Inhalt des Menüleisten-Fensters: System-Karte und drei Gruppen-Karten in
/// Liquid Glass — als Liste oder als 2×2-Raster.
struct DropdownView: View {
    @Bindable var engine: StatsEngine
    var fans: FanService = .shared
    var updates: UpdateChecker = .shared
    var panel: PanelSettings = .shared
    var shelf: FileShelf = .shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let size = engine.cardSize
        CompatGlassContainer(spacing: size.outerSpacing) {
            content(size: size)
        }
        .frame(width: engine.dropdownWidth)
    }

    /// Der Inhalt wird scrollbar, sobald er höher als der Bildschirm wäre —
    /// mit Ablage und großen Kacheln passen sonst nicht alle Karten.
    /// `ImageRenderer` stellt ScrollView-Inhalte nicht dar, im Snapshot-Modus
    /// bleibt der Stapel deshalb ungescrollt.
    @ViewBuilder
    private func content(size: CardSize) -> some View {
        if DebugSnapshot.isActive {
            stack(size: size)
        } else {
            ScrollView {
                stack(size: size)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: Self.maxContentHeight)
        }
    }

    private func stack(size: CardSize) -> some View {
        VStack(spacing: size.outerSpacing) {
            header

            if let release = updates.available {
                updateBanner(release)
            }

            let rows = DashboardCard.rows(visibleCards, layout: engine.layout)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if row.count == 1 {
                    card(row[0])
                } else {
                    HStack(alignment: .top, spacing: size.outerSpacing) {
                        ForEach(row) { card($0, compact: engine.layout == .split) }
                    }
                    // Beide Karten der Zeile bekommen dieselbe Höhe
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            footer
        }
        .padding(size.outerPadding)
    }

    /// Platz unterhalb der Menüleiste auf dem Bildschirm mit der Menüleiste.
    private static var maxContentHeight: CGFloat {
        max(400, (NSScreen.screens.first?.visibleFrame.height ?? 900) - 12)
    }

    /// Die vier Mess-Karten, dahinter optional die Ablage.
    private var visibleCards: [DashboardCard] {
        var cards: [DashboardCard] = [.system, .internalDrives, .externalDrives, .network]
        if shelf.showInDropdown, Entitlements.shared.isUnlocked(.fileShelf) {
            cards.append(.shelf)
        }
        return cards
    }

    private func card(_ card: DashboardCard, compact: Bool = false) -> some View {
        DashboardCardView(card: card, engine: engine, fans: fans, shelf: shelf, compact: compact)
    }

    private var header: some View {
        HStack(spacing: 8) {
            FlooshWordmark(height: 24)
            Spacer()
            Button {
                panel.enabled.toggle()
            } label: {
                Image(systemName: panel.enabled ? "rectangle.inset.filled.on.rectangle" : "rectangle.on.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .compatGlassButton()
            .featureGated(.desktopPanel)
            .help(panel.enabled ? "Desktop-Panel ausblenden" : "Desktop-Panel anzeigen")

            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .compatGlassButton()
            .help("Einstellungen …")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .compatGlassButton()
            .help("floosh beenden")
        }
        .padding(.horizontal, 2)
    }

    /// Schmale Zeile, sobald auf GitHub eine neuere Version liegt.
    private func updateBanner(_ release: UpdateChecker.Release) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("floosh \(release.version) ist verfügbar")
                .font(.caption.weight(.semibold))
            Spacer(minLength: 8)
            Button("Laden") { updates.openDownload(release) }
                .compatGlassButton()
                .controlSize(.small)
                .help("DMG von GitHub laden")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .cardGlass(tint: Color.accentColor.opacity(0.12), cornerRadius: 14)
    }

    /// Dezente Credit-Zeile: die JRN.digital-Wortmarke, klickbar zur Website.
    private var footer: some View {
        Link(destination: URL(string: "https://jrn.digital")!) {
            JRNLogo(height: 9)
                .opacity(0.75)
        }
        .buttonStyle(.plain)
        .help("Entwickelt von JRN.digital")
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 2)
        .padding(.top, -4)
    }
}


/// Wählt die passende Karte — gemeinsam genutzt von Dropdown und Desktop-Panel.
struct DashboardCardView: View {
    let card: DashboardCard
    let engine: StatsEngine
    var fans: FanService = .shared
    var shelf: FileShelf = .shared
    /// Halbe Breite (geteiltes Layout) — nur die Laufwerks-Karten kennen das.
    var compact = false

    var body: some View {
        switch card {
        case .system: SystemCard(engine: engine, fans: fans)
        case .internalDrives: GroupCard(engine: engine, group: .internalDrives, compact: compact)
        case .externalDrives: GroupCard(engine: engine, group: .externalDrives, compact: compact)
        case .network: GroupCard(engine: engine, group: .network, compact: compact)
        case .shelf: ShelfCard(engine: engine, shelf: shelf)
        }
    }
}
