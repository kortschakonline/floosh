import SwiftUI
import ServiceManagement

enum SettingsTab: String, CaseIterable {
    case display, measurement, fans, panel, tools, general
}

/// Eigenständiges Einstellungs-Fenster (⌘,) mit Tabs — hier ist Platz für mehr.
struct SettingsWindow: View {
    @Bindable var engine: StatsEngine
    @Bindable private var shelf = FileShelf.shared
    @Bindable private var catcher = DragCatcher.shared
    @State private var selectedTab: SettingsTab
    /// In einem eigenen, größenveränderbaren Fenster darf der Inhalt scrollen —
    /// der Anzeige-Tab ist höher als der Bildschirm.
    private let fixedHeight: Bool

    init(engine: StatsEngine, initialTab: SettingsTab = .display, fixedHeight: Bool = true) {
        self.engine = engine
        self.fixedHeight = fixedHeight
        _selectedTab = State(initialValue: initialTab)
    }

    @ViewBuilder
    var body: some View {
        if fixedHeight {
            tabs
                .frame(width: 440)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            tabs
                .frame(minWidth: 440, minHeight: 320)
        }
    }

    /// Die `Tab`-Syntax gibt es erst ab macOS 15 — davor `tabItem`.
    @ViewBuilder
    private var tabs: some View {
        if #available(macOS 15.0, *) {
            TabView(selection: $selectedTab) {
                Tab("Anzeige", systemImage: "paintbrush", value: .display) {
                    displayTab
                }
                Tab("Messung", systemImage: "gauge.with.dots.needle.67percent", value: .measurement) {
                    measurementTab
                }
                Tab("Lüfter", systemImage: "fan", value: .fans) {
                    FanSettingsTab(fans: FanService.shared)
                }
                Tab("Panel", systemImage: "rectangle.on.rectangle", value: .panel) {
                    PanelSettingsTab(panel: PanelSettings.shared)
                }
                Tab("Werkzeuge", systemImage: "wrench.and.screwdriver", value: .tools) {
                    ToolsSettingsTab()
                }
                Tab("Allgemein", systemImage: "gearshape", value: .general) {
                    generalTab
                }
            }
        } else {
            TabView(selection: $selectedTab) {
                displayTab
                    .tabItem { Label("Anzeige", systemImage: "paintbrush") }
                    .tag(SettingsTab.display)
                measurementTab
                    .tabItem { Label("Messung", systemImage: "gauge.with.dots.needle.67percent") }
                    .tag(SettingsTab.measurement)
                FanSettingsTab(fans: FanService.shared)
                    .tabItem { Label("Lüfter", systemImage: "fan") }
                    .tag(SettingsTab.fans)
                PanelSettingsTab(panel: PanelSettings.shared)
                    .tabItem { Label("Panel", systemImage: "rectangle.on.rectangle") }
                    .tag(SettingsTab.panel)
                ToolsSettingsTab()
                    .tabItem { Label("Werkzeuge", systemImage: "wrench.and.screwdriver") }
                    .tag(SettingsTab.tools)
                generalTab
                    .tabItem { Label("Allgemein", systemImage: "gearshape") }
                    .tag(SettingsTab.general)
            }
        }
    }

    // MARK: Anzeige

    private var displayTab: some View {
        Form {
            Picker("Stil in der Menüleiste", selection: $engine.labelStyle) {
                ForEach(MenuLabelStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Symbol", selection: $engine.iconStyle) {
                ForEach(MenuIconStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Einheit", selection: $engine.units) {
                ForEach(SpeedUnits.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Werte", selection: $engine.menuChannel) {
                ForEach(MenuChannel.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .featureGated(.menuChannel)

            Section("Zusätze in der Menüleiste") {
                Picker("CPU & GPU", selection: $engine.menuSystemStyle) {
                    ForEach(MenuSystemStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Temperatur & Lüfter", selection: $engine.menuThermal) {
                    ForEach(MenuThermalStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .featureGated(.menuThermal)

                Toggle("Verlauf der letzten 30 s (Sparkline)", isOn: $engine.menuSparkline)
                    .featureGated(.menuSparkline)
                Toggle("Werte nur bei Aktivität (ab 100 KB/s)", isOn: $engine.menuHideIdle)
                    .featureGated(.menuHideIdle)
                Toggle("Zahlen in Gruppenfarbe", isOn: $engine.menuTintText)
                    .disabled(engine.iconStyle != .color)
                    .featureGated(.menuTintText)
                if engine.iconStyle != .color {
                    Text("Farbige Zahlen gibt es nur beim Symbol „Farbig“ — Outline und Gefüllt sind einfarbige Systemsymbole.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Dropdown") {
                Picker("Anordnung", selection: $engine.layout) {
                    ForEach(DropdownLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .featureGated(.gridLayout)

                Picker("Kachelgröße", selection: $engine.cardSize) {
                    ForEach(CardSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .featureGated(.cardSize)

                Picker("Aktive Kachel", selection: $engine.selectionStyle) {
                    ForEach(SelectionStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .featureGated(.selectionStyle)

                Toggle("Spitzenwerte anzeigen", isOn: $engine.showPeaks)
                Toggle("Einzelne Geräte anzeigen", isOn: $engine.showDevices)
            }

            Section("Hintergrund") {
                LabeledContent("Fläche") {
                    Slider(value: $engine.backdropOpacity, in: 0...1)
                        .frame(width: 200)
                }
                LabeledContent("Kacheln") {
                    Slider(value: $engine.cardOpacity, in: 0...1)
                        .frame(width: 200)
                }
                Text("„Fläche\u{201C} legt einen durchgehenden Grund hinter alle Kacheln — auf 0 scheint zwischen ihnen der Schreibtisch durch. „Kacheln\u{201C} macht das Glas der einzelnen Kacheln dichter. Beides gilt auch fürs Desktop-Panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Reihenfolge der Kacheln") {
                CardOrderEditor(engine: engine)
                Text("Gilt für Dropdown und Desktop-Panel. Welche Kacheln überhaupt erscheinen, steht oben bzw. im Tab „Panel\u{201C}.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Ablage") {
                Toggle("Ablage im Dropdown anzeigen", isOn: $shelf.showInDropdown)
                    .featureGated(.fileShelf)
                Toggle("Beim Beenden von floosh leeren", isOn: $shelf.clearOnQuit)
                    .featureGated(.fileShelf)

                Toggle("Fangstreifen beim Ziehen einblenden", isOn: $catcher.enabled)
                    .featureGated(.dragCatcher)
                Picker("Kante", selection: $catcher.edge) {
                    ForEach(DragCatcher.Edge.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!catcher.enabled)
                Text("Sobald irgendwo Dateien gezogen werden, erscheint ein Ablegefeld an dieser Kante des Bildschirms, auf dem der Zeiger gerade ist — kein Zielen auf das Menüleisten-Symbol, kein Wegräumen von Fenstern.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Dateien in die Ablage ziehen, um sie kurz zu parken, und von dort weiterziehen. floosh merkt sich nur den Ort und kopiert nichts. Im Desktop-Panel lässt sich die Ablage unter „Karten\u{201C} zuschalten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Messung

    private var measurementTab: some View {
        Form {
            Picker("Intervall", selection: $engine.interval) {
                Text("0,5 s").tag(0.5)
                Text("1 s").tag(1.0)
                Text("2 s").tag(2.0)
            }
            .pickerStyle(.segmented)

            Picker("Diagramm-Zeitfenster", selection: $engine.chartWindow) {
                Text("30 s").tag(30.0)
                Text("60 s").tag(60.0)
                Text("120 s").tag(120.0)
            }
            .pickerStyle(.segmented)

            Section("Quellen") {
                Toggle("Disk-Images mitzählen", isOn: $engine.includeVirtualDisks)
                Toggle("VPN & virtuelle Interfaces mitzählen", isOn: $engine.includeVirtualNets)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Allgemein

    private var generalTab: some View {
        GeneralSettingsTab(updates: UpdateChecker.shared)
    }
}

/// Lüfter-Tab: Temperaturkurve, Drehzahl-Favoriten und Status des
/// privilegierten Helpers.
private struct FanSettingsTab: View {
    @Bindable var fans: FanService

    var body: some View {
        Form {
            Section("Lüfterkurve") {
                Picker("Sensor", selection: $fans.curve.source) {
                    ForEach(FanCurve.Source.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                FanCurveChart(curve: fans.curve, temp: fans.curveTemp, target: fans.curveTarget,
                              tint: SystemCard.tint)
                    .frame(height: 130)
                    .padding(.vertical, 4)

                ForEach($fans.curve.points) { $point in
                    curvePointRow($point)
                }

                HStack {
                    Button("Punkt hinzufügen") { fans.curve.addPoint() }
                        .disabled(fans.curve.points.count >= FanCurve.maxPoints)
                    Spacer()
                    Button("Standardkurve") { fans.curve = .standard }
                        .disabled(fans.curve.points.map { ($0.temp, $0.percent) }
                            .elementsEqual(FanCurve.standard.points.map { ($0.temp, $0.percent) }, by: ==)
                            && fans.curve.source == FanCurve.standard.source)
                }
                .controlSize(.small)

                Text("Im Kurven-Modus regelt floosh die Lüfter nach der Die-Temperatur: zwischen den Punkten wird linear interpoliert, die Temperatur wird geglättet (schnell hoch, langsam zurück). Der Kurven-Modus bleibt über einen Neustart aktiv.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Drehzahl-Favoriten") {
                favoriteRow(label: "Favorit 1", value: $fans.favorite1)
                favoriteRow(label: "Favorit 2", value: $fans.favorite2)
                Text("Die Favoriten erscheinen als Schnellwahl-Knöpfe im Dropdown (Manuell-Modus).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Steuerung") {
                LabeledContent("System-Helfer") {
                    switch fans.helperState {
                    case .ready:
                        Label("Aktiv", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .needsApproval:
                        Button("In Systemeinstellungen erlauben …") { fans.openApprovalSettings() }
                    case .needsRegistration:
                        Button("Aktivieren …") { fans.registerHelper() }
                    case .staleRegistration:
                        Button("Neu registrieren …") { fans.reregisterHelper() }
                    case .unavailable(let reason):
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text("Manuelle Lüftersteuerung und Kurve brauchen einen kleinen Root-Helfer (einmalige Freigabe unter Anmeldeobjekte). Sicherheitsnetz: Ohne Lebenszeichen der App schaltet er nach 3 Minuten selbstständig zurück auf Automatik.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if fans.helperState == .staleRegistration {
                    Text("Die vorhandene Registrierung gehört zu einer älteren Ausgabe von floosh. Weil die App ad-hoc signiert ist, bekommt jeder Build eine neue Kennung, und das System lässt den Helfer dann nicht mehr starten. „Neu registrieren\u{201C} meldet ihn ab und wieder an; danach kann eine erneute Freigabe unter Anmeldeobjekte nötig sein.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { fans.refreshHelperState() }
    }

    /// Ein Stützpunkt: Temperatur-Regler, Prozent-Regler, Entfernen-Knopf.
    /// Nach dem Loslassen des Temperatur-Reglers wird die Liste neu sortiert.
    private func curvePointRow(_ point: Binding<FanCurve.Point>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "thermometer.medium")
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Slider(value: point.temp, in: FanCurve.tempRange, step: 1) { editing in
                if !editing { fans.curve.normalize() }
            }
            Text("\(Int(point.wrappedValue.temp)) °C")
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)

            Image(systemName: "fan")
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .padding(.leading, 6)
            Slider(value: point.percent, in: 0...100, step: 5)
            Text("\(Int(point.wrappedValue.percent)) %")
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)

            Button {
                fans.curve.points.removeAll { $0.id == point.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(fans.curve.points.count <= 2)
            .help("Punkt entfernen")
        }
        .controlSize(.small)
    }

    private func favoriteRow(label: String, value: Binding<Double>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Slider(value: value, in: 0...100, step: 5)
                    .frame(width: 160)
                Text("\(Int(value.wrappedValue)) %")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

/// Panel-Tab: Desktop-Panel ein/aus, Ebene, Position, Deckkraft, Karten.
private struct PanelSettingsTab: View {
    @Bindable var panel: PanelSettings

    var body: some View {
        Form {
            Section {
                Toggle("Desktop-Panel anzeigen", isOn: $panel.enabled)
                    .featureGated(.desktopPanel)
                Text("Zeigt die Karten dauerhaft auf dem Schreibtisch — Größe folgt der Kachelgröße unter Anzeige.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Darstellung") {
                Picker("Ebene", selection: $panel.level) {
                    ForEach(PanelSettings.Level.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(panel.level.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Anordnung", selection: $panel.layout) {
                    ForEach(DropdownLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                LabeledContent("Deckkraft") {
                    HStack(spacing: 8) {
                        Slider(value: $panel.opacity, in: 0.3...1, step: 0.05)
                            .frame(width: 160)
                        Text("\(Int((panel.opacity * 100).rounded())) %")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section("Position") {
                Picker("Ecke", selection: $panel.position) {
                    ForEach(PanelSettings.Position.allCases) { Text($0.title).tag($0) }
                }

                LabeledContent("Abstand vom Rand") {
                    HStack(spacing: 8) {
                        Slider(value: $panel.margin, in: 0...200, step: 4)
                            .frame(width: 160)
                        Text("\(Int(panel.margin)) pt")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                Picker("Bildschirm", selection: $panel.screenName) {
                    Text("Hauptbildschirm").tag("")
                    ForEach(DesktopPanelController.screenNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }

                Toggle("Auf allen Schreibtischen", isOn: $panel.allSpaces)
            }

            Section("Karten") {
                ForEach(PanelSettings.Card.allCases) { card in
                    Toggle(card.title, isOn: panel.binding(for: card))
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettingsTab: View {
    @Bindable var updates: UpdateChecker
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        FlooshWordmark(height: 30)
                        Text("Version \(UpdateChecker.currentVersion ?? "dev")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link(destination: URL(string: "https://jrn.digital")!) {
                        JRNLogo(height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("jrn.digital öffnen")
                }
                .padding(.vertical, 4)
            }

            Toggle("Bei Anmeldung starten", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    updateLoginItem(enabled: newValue)
                }
            if let loginError {
                Text(loginError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Section("Updates") {
                Toggle("Automatisch nach Updates suchen", isOn: $updates.automatic)
                    .featureGated(.updateCheck)

                LabeledContent("Status") {
                    updateStatus
                }

                if let release = updates.available {
                    HStack(spacing: 8) {
                        Button("Laden") { updates.openDownload(release) }
                            .buttonStyle(.borderedProminent)
                        Button("Release-Seite") { updates.openPage(release) }
                        Spacer()
                        Button("Überspringen") { updates.skip(release) }
                    }
                    .controlSize(.small)
                }

                HStack {
                    Button(updates.isChecking ? "Prüfe …" : "Jetzt prüfen") {
                        Task { await updates.check() }
                    }
                    .disabled(updates.isChecking)
                    .controlSize(.small)
                    Spacer()
                    Link("GitHub-Releases", destination: URL(string: "https://github.com/\(UpdateChecker.repository)/releases")!)
                        .font(.caption)
                }
            }

            Section {
                LabeledContent("Entwickelt von") {
                    Link("jrn.digital", destination: URL(string: "https://jrn.digital")!)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var updateStatus: some View {
        if updates.isChecking {
            Text("Prüfe …").foregroundStyle(.secondary)
        } else if let error = updates.lastError {
            Text(error).foregroundStyle(.orange)
        } else if let release = updates.available {
            Label("Version \(release.version) verfügbar", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
        } else if let latest = updates.latest, let checked = updates.lastChecked {
            let skipped = latest.version == updates.skippedVersion
            Text(skipped
                 ? "Version \(latest.version) übersprungen"
                 : "floosh ist aktuell (geprüft \(checked.formatted(date: .omitted, time: .shortened)))")
                .foregroundStyle(.secondary)
        } else if UpdateChecker.currentVersion == nil {
            Text("Entwicklungs-Build — keine Prüfung").foregroundStyle(.secondary)
        } else {
            Text("Noch nicht geprüft").foregroundStyle(.secondary)
        }
    }

    private func updateLoginItem(enabled: Bool) {
        loginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginError = "Login-Start nicht möglich: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}


/// Reihenfolge der Kacheln: eine Zeile je Karte, verschoben wird mit den
/// Pfeilen. Bewusst keine Ziehliste — eine `List` in einem `Form` bringt
/// ihre eigene Höhe mit und sprengt den Tab.
private struct CardOrderEditor: View {
    @Bindable var engine: StatsEngine

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(engine.cardOrder.enumerated()), id: \.element) { index, card in
                HStack(spacing: 8) {
                    Image(systemName: card.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(card.title)
                    Spacer()
                    Button {
                        engine.moveCard(card, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(index == 0)
                    .help("Nach oben")

                    Button {
                        engine.moveCard(card, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(index == engine.cardOrder.count - 1)
                    .help("Nach unten")
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 4)

                if index < engine.cardOrder.count - 1 {
                    Divider()
                }
            }
        }
    }

}

/// Werkzeuge: Wachhalten, Bildschirm reinigen und die Kurzbefehle-Karte.
private struct ToolsSettingsTab: View {
    @Bindable private var awake = KeepAwake.shared
    @Bindable private var clean = CleanScreen.shared
    @Bindable private var shortcuts = ShortcutsService.shared
    @Bindable private var tools = ToolSettings.shared

    var body: some View {
        Form {
            Section("Wachhalten") {
                Picker("Dauer", selection: $awake.duration) {
                    ForEach(KeepAwake.Duration.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(awake.isActive)

                LabeledContent("Zustand") {
                    HStack(spacing: 8) {
                        if awake.isActive {
                            Text(awake.remainingText.map { "aktiv, noch \($0)" } ?? "aktiv")
                                .foregroundStyle(.green)
                        } else {
                            Text("aus").foregroundStyle(.secondary)
                        }
                        Button(awake.isActive ? "Beenden" : "Starten") { awake.toggle() }
                    }
                }
                Text("Verhindert, dass der Bildschirm in den Ruhezustand geht — wie „caffeinate\u{201C}, ohne Terminal. Wird beim Beenden von floosh und beim Ablauf der Dauer automatisch aufgehoben und startet nach einem Neustart nicht von selbst wieder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Bildschirm reinigen") {
                Picker("Dauer", selection: $clean.seconds) {
                    ForEach(CleanScreen.choices, id: \.self) { Text("\($0) s").tag($0) }
                }
                .pickerStyle(.segmented)

                Button("Jetzt abdunkeln") { clean.start() }

                Text("Dunkelt alle Bildschirme ab und schluckt Klicks und Tasten, damit beim Putzen nichts ausgelöst wird. Endet nach der eingestellten Zeit oder sofort mit Escape. Systemweite Kürzel wie ⌘-Tab fängt macOS vor jeder App ab — die bleiben aktiv.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("In der System-Karte") {
                Toggle("Knöpfe für Wachhalten und Reinigen zeigen", isOn: $tools.showTools)
            }

            Section("Kurzbefehle") {
                if shortcuts.isAvailable {
                    Toggle("Karte im Dropdown anzeigen", isOn: $shortcuts.showInDropdown)
                        .featureGated(.shortcuts)

                    if shortcuts.available.isEmpty {
                        LabeledContent("Kurzbefehle") {
                            Button("Laden") { Task { await shortcuts.refresh() } }
                        }
                    } else {
                        ShortcutsChooser(shortcuts: shortcuts)
                    }

                    Text("Ausgewählte Kurzbefehle erscheinen als Knöpfe in der Karte und laufen im Hintergrund (`shortcuts run`). Die Karte lässt sich unter Anzeige → Reihenfolge einsortieren und im Tab „Panel\u{201C} auch aufs Desktop-Panel legen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Auf diesem Mac gibt es die Kurzbefehle-Kommandozeile nicht (`/usr/bin/shortcuts`).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await shortcuts.refresh() }
    }
}

/// Auswahl und Reihenfolge der Kurzbefehle: oben die gewählten (sortierbar),
/// darunter alle übrigen zum Hinzufügen.
private struct ShortcutsChooser: View {
    @Bindable var shortcuts: ShortcutsService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !shortcuts.chosen.isEmpty {
                ForEach(Array(shortcuts.chosen.enumerated()), id: \.element) { index, name in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                        Text(name).lineLimit(1)
                        Spacer()
                        Button { shortcuts.move(name, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                        Button { shortcuts.move(name, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == shortcuts.chosen.count - 1)
                        Button { shortcuts.toggle(name) } label: { Image(systemName: "minus.circle") }
                            .help("Aus der Karte entfernen")
                    }
                    .buttonStyle(.borderless)
                }
                Divider()
            }

            let rest = shortcuts.available.filter { !shortcuts.chosen.contains($0) }
            if rest.isEmpty {
                Text("Alle Kurzbefehle sind ausgewählt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rest, id: \.self) { name in
                    HStack(spacing: 8) {
                        Image(systemName: "circle")
                            .foregroundStyle(.secondary)
                        Text(name).lineLimit(1)
                        Spacer()
                        Button { shortcuts.toggle(name) } label: { Image(systemName: "plus.circle") }
                            .help("Als Knopf in die Karte")
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack {
                Spacer()
                Button("Liste neu laden") { Task { await shortcuts.refresh() } }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }
}
