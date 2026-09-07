import SwiftUI

/// Inhalt des Menüleisten-Fensters: System-Karte und drei Gruppen-Karten in
/// Liquid Glass — als Liste oder als 2×2-Raster.
struct DropdownView: View {
    @Bindable var engine: StatsEngine
    var fans: FanService = .shared
    var updates: UpdateChecker = .shared
    var panel: PanelSettings = .shared
    var shelf: FileShelf = .shared

    var body: some View {
        let size = engine.cardSize
        CompatGlassContainer(spacing: size.outerSpacing) {
            content(size: size)
        }
        .frame(width: engine.dropdownWidth)
        // Trägerfläche hinter allen Karten; ohne sie scheint zwischen ihnen
        // der Schreibtisch durch. Etwas runder als die Karten selbst.
        .dashboardBackdrop(opacity: engine.backdropOpacity,
                           cornerRadius: size.cornerRadius + 6)
        .environment(\.cardInkOpacity, engine.cardOpacity)
        // Das ganze Fenster nimmt Dateien an, nicht nur die Ablage-Karte —
        // beim Ziehen soll man nicht zielen müssen.
        .dropDestination(for: URL.self) { urls, _ in
            MenuBarController.shared?.accept(urls) ?? (shelf.add(urls) > 0)
        } isTargeted: { targeted in
            if targeted { MenuBarController.shared?.dragEnteredPanel() }
        }
    }

    /// Kein ScrollView: Das Fenster von `MenuBarExtra` fragt nur die Idealgröße
    /// des Inhalts ab — ein ScrollView meldet dort keine und das Fenster
    /// schrumpft auf einen Strich zusammen.
    private func content(size: CardSize) -> some View {
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

    /// Die vier Mess-Karten und optional die Ablage — in der Reihenfolge,
    /// die unter Einstellungen → Anzeige eingestellt ist.
    private var visibleCards: [DashboardCard] {
        var cards: Set<DashboardCard> = [.system, .internalDrives, .externalDrives, .network]
        if shelf.showInDropdown, Entitlements.shared.isUnlocked(.fileShelf) {
            cards.insert(.shelf)
        }
        if ShortcutsService.shared.showInDropdown, Entitlements.shared.isUnlocked(.shortcuts) {
            cards.insert(.shortcuts)
        }
        return engine.ordered(cards)
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
                SettingsLauncher.open()
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
        case .shortcuts: ShortcutsCard(engine: engine, shortcuts: .shared)
        }
    }
}
