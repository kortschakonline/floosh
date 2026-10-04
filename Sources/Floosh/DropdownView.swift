import SwiftUI

/// Inhalt des Menüleisten-Fensters: System-Karte und drei Gruppen-Karten in
/// Liquid Glass — als Liste oder als 2×2-Raster.
struct DropdownView: View {
    @Bindable var engine: StatsEngine
    var fans: FanService = .shared
    var updates: UpdateChecker = .shared
    var panel: PanelSettings = .shared
    var shelf: FileShelf = .shared

    /// Anordnen-Modus: Kacheln ziehen und ausblenden. Solange er an ist,
    /// reagieren die Kacheln selbst nicht auf Klicks — so kommen sich Ziehen,
    /// Lüfter-Regler und Ablage-Drags nicht in die Quere.
    /// `--arrange` (Dev-Hook für Bildprüfungen) startet direkt im Anordnen-Modus.
    @State private var arranging = CommandLine.arguments.contains("--arrange")
    /// Kachel, über der gerade eine andere schwebt (Einfügemarke).
    @State private var dropTarget: DashboardCard?

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

    /// Kein ScrollView hier drin: Gescrollt wird außen im Menüleisten-Fenster
    /// (`MenuPanelContent`), das die Idealgröße dieses Views misst.
    private func content(size: CardSize) -> some View {
        VStack(spacing: size.outerSpacing) {
            header

            if let release = updates.available {
                updateBanner(release)
            }

            let columns = engine.freeColumns
            let rows = DashboardCard.rows(visibleCards, layout: engine.layout, columns: columns)
            ForEach(rows, id: \.self) { row in
                if row.count == 1, (columns ?? 1) == 1 {
                    card(row[0])
                } else {
                    HStack(alignment: .top, spacing: size.outerSpacing) {
                        ForEach(row) { card($0, compact: columns == nil && engine.layout == .split) }
                        // Letzte Zeile nicht voll: Lücken füllen, damit die
                        // Kacheln ihre Spaltenbreite behalten
                        if let columns, row.count < columns {
                            ForEach(0..<(columns - row.count), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            }
                        }
                    }
                    // Alle Karten der Zeile bekommen dieselbe Höhe
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            if arranging {
                arrangeBar
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
        if engine.battery != nil { cards.insert(.battery) }
        return engine.shownInDropdown(cards)
    }

    /// Ausgeblendete Kacheln, die man im Anordnen-Modus zurückholen kann.
    private var hiddenAvailableCards: [DashboardCard] {
        var cards: Set<DashboardCard> = [.system, .internalDrives, .externalDrives, .network]
        if shelf.showInDropdown { cards.insert(.shelf) }
        if ShortcutsService.shared.showInDropdown { cards.insert(.shortcuts) }
        if engine.battery != nil { cards.insert(.battery) }
        return engine.ordered(cards).filter(engine.hiddenCards.contains)
    }

    @ViewBuilder
    private func card(_ card: DashboardCard, compact: Bool = false) -> some View {
        let view = DashboardCardView(card: card, engine: engine, fans: fans, shelf: shelf, compact: compact)
        if arranging {
            ArrangeableCard(card: card, size: engine.cardSize,
                            isDropTarget: dropTarget == card) {
                view
            } onHide: {
                withAnimation(.snappy) { _ = engine.hiddenCards.insert(card) }
            }
            .draggable(CardDrag.token(for: card)) {
                ArrangeDragPreview(card: card)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let moved = items.lazy.compactMap(CardDrag.card(from:)).first else { return false }
                withAnimation(.snappy) { engine.moveCard(moved, before: card) }
                return true
            } isTargeted: { targeted in
                if targeted { dropTarget = card } else if dropTarget == card { dropTarget = nil }
            }
        } else {
            view
        }
    }

    private var currentColumns: Int {
        engine.freeColumns ?? engine.chosenColumns
    }

    private var columnSymbol: String {
        switch currentColumns {
        case 1: "rectangle"
        case 2: "rectangle.split.2x1"
        default: "rectangle.split.3x1"
        }
    }

    /// Unter den Kacheln im Anordnen-Modus: Ablage-Ziel „ans Ende",
    /// ausgeblendete Kacheln zum Zurückholen und „Fertig".
    private var arrangeBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Kacheln ziehen zum Umsortieren · hier ablegen = ans Ende")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if !hiddenAvailableCards.isEmpty {
                HStack(spacing: 6) {
                    Text("Ausgeblendet:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(hiddenAvailableCards) { card in
                        Button {
                            withAnimation(.snappy) { _ = engine.hiddenCards.remove(card) }
                        } label: {
                            Label(card.title, systemImage: "plus")
                                .font(.caption)
                        }
                        .compatGlassButton()
                        .controlSize(.small)
                        .help("\(card.title) wieder einblenden")
                    }
                }
            }

            HStack {
                Toggle("Extern ausblenden, wenn kein Laufwerk dran ist",
                       isOn: $engine.hideEmptyExternal)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer(minLength: 8)
                Button("Fertig") {
                    withAnimation(.snappy) { arranging = false }
                }
                .compatGlassButton()
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardGlass(cornerRadius: engine.cardSize.cornerRadius)
        .dropDestination(for: String.self) { items, _ in
            guard let moved = items.lazy.compactMap(CardDrag.card(from:)).first else { return false }
            withAnimation(.snappy) { engine.moveCard(moved, before: nil) }
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Griff zum Verschieben des Fensters; Doppelklick dockt wieder an
            FlooshWordmark(height: 24)
                .padding(.vertical, 4)
                .padding(.trailing, 24)
                .background {
                    WindowDragHandle {
                        MenuBarController.shared?.panelWasMoved()
                    } onDoubleClick: {
                        MenuBarController.shared?.redock()
                    }
                }
                .help("Ziehen zum Verschieben · Doppelklick: wieder unter dem Symbol andocken")
            Spacer()

            Button {
                withAnimation(.snappy) { engine.cycleColumns() }
            } label: {
                Image(systemName: columnSymbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .compatGlassButton()
            .help("Spalten: \(currentColumns) — klicken für \(currentColumns % 3 + 1)")

            Button {
                withAnimation(.snappy) { arranging.toggle() }
            } label: {
                Image(systemName: arranging ? "checkmark" : "square.grid.2x2")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .compatGlassButton()
            .help(arranging ? "Anordnen beenden" : "Kacheln anordnen und ausblenden")

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
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        // Verschwommene, dunkel getönte Leiste: Das Logo ist hell und die
        // Knöpfe sind Glas — auf hellem Schreibtisch sonst kaum zu sehen
        .background {
            RoundedRectangle(cornerRadius: engine.cardSize.cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: engine.cardSize.cornerRadius, style: .continuous)
                        .fill(.black.opacity(0.28))
                }
                .environment(\.colorScheme, .dark)
        }
        .environment(\.colorScheme, .dark)
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
        case .battery: BatteryCard(engine: engine)
        }
    }
}
