import SwiftUI
import AppKit

/// Oberfläche der floosh-Island. Die Form wächst aus der Notch heraus
/// (bzw. aus der Pille), Inhalte blenden je nach Zustand ein.
struct IslandView: View {
    @Bindable var model: IslandModel
    let engine: StatsEngine
    var settings: IslandSettings = .shared

    private let spring = Animation.spring(response: 0.38, dampingFraction: 0.78)

    var body: some View {
        let size = model.currentSize
        ZStack(alignment: .top) {
            shape
                .fill(.black)
                .shadow(color: .black.opacity(model.mode == .expanded ? 0.45 : 0), radius: 18, y: 8)

            content
                .clipShape(shape)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        // Klick und Ablegen nur auf der sichtbaren Form
        .contentShape(shape)
        .onTapGesture {
            if model.mode != .expanded { IslandController.shared.toggleExpanded() }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let added = FileShelf.shared.add(urls)
            if added > 0 {
                model.tab = .shelf
                IslandController.shared.setMode(.expanded)
            }
            return added > 0
        } isTargeted: { targeted in
            model.isDropTarget = targeted
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(spring, value: model.mode)
        .animation(spring, value: model.tab)
    }

    private var shape: IslandShape {
        IslandShape(ear: model.hasNotch ? IslandModel.ear : 0,
                    radius: model.mode == .expanded ? 26 : (model.mode == .peek ? 18 : (model.hasNotch ? 9 : model.core.height / 2)))
    }

    // MARK: Inhalt je Zustand

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .idle:
            topRow { sideValue(settings.left) } trailing: { sideValue(settings.right) }
                .transition(.opacity)
        case .alert:
            if let alert = model.alert {
                topRow {
                    Image(systemName: alert.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(alert.color)
                } trailing: {
                    Text(alert.text)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .transition(.opacity)
            }
        case .peek:
            VStack(spacing: 6) {
                topRow { sideValue(settings.left) } trailing: { sideValue(settings.right) }
                IslandPeekRow(engine: engine)
                    .padding(.horizontal, 22)
            }
            .transition(.opacity)
        case .expanded:
            VStack(spacing: 10) {
                expandedHeader
                Group {
                    switch model.tab {
                    case .live: IslandLiveTab(engine: engine)
                    case .shelf: IslandShelfTab(shelf: .shared, isDropTarget: model.isDropTarget)
                    case .music: IslandMusicTab(player: .shared)
                    case .battery: IslandBatteryTab(engine: engine)
                    case .tools: IslandToolsTab(engine: engine)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        }
    }

    /// Obere Zeile auf Notch-Höhe: links und rechts der Kamera.
    private func topRow<L: View, T: View>(@ViewBuilder leading: () -> L,
                                           @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 0) {
            leading()
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: model.hasNotch ? model.core.width : 16)
            trailing()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, (model.hasNotch ? IslandModel.ear : 0) + 12)
        .frame(height: model.core.height)
        .foregroundStyle(.white)
    }

    /// Eigene View: Nur sie liest die sekündlich wechselnden Messwerte —
    /// so wird pro Runde nicht die ganze Island neu ausgewertet.
    private func sideValue(_ value: IslandValue) -> some View {
        IslandSideValue(value: value, engine: engine)
    }

    /// Aufgeklappt: Tabs links, Dropdown/Einstellungen rechts — unterhalb der Notch.
    private var expandedHeader: some View {
        HStack(spacing: 6) {
            ForEach(availableTabs) { tab in
                Button {
                    model.tab = tab
                } label: {
                    Label(tab.title, systemImage: tab.symbol)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 24)
                        .background(model.tab == tab ? Color.white.opacity(0.18) : .clear,
                                    in: .rect(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
            Spacer(minLength: 0)
            Button {
                IslandController.shared.setMode(.idle)
                SettingsLauncher.open()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help("Einstellungen …")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.top, model.core.height + 4)
    }

    private var availableTabs: [IslandTab] {
        IslandTab.allCases.filter { $0 != .battery || engine.battery != nil }
    }
}

/// Ein Wert neben der Notch (Ruhe/Vorschau).
private struct IslandSideValue: View {
    let value: IslandValue
    let engine: StatsEngine

    var body: some View {
        if let text = IslandFormat.value(value, engine: engine) {
            HStack(spacing: 4) {
                Image(systemName: IslandFormat.symbol(value, engine: engine))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(IslandFormat.tint(value, engine: engine))
                Text(text)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

// MARK: - Form

/// Notch-Form: oben bündig, an den oberen Ecken nach außen geschwungene
/// „Ohren" (wie die echte Notch in die Menüleiste übergeht), unten gerundet.
/// Ohne Ohren eine abgerundete Pille.
struct IslandShape: Shape {
    var ear: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, radius) }
        set { ear = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, (rect.height) / 2, (rect.width - 2 * ear) / 2)
        var p = Path()
        if ear > 0 {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: rect.minX + ear, y: rect.minY + ear),
                           control: CGPoint(x: rect.minX + ear, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + ear, y: rect.maxY - r))
            p.addQuadCurve(to: CGPoint(x: rect.minX + ear + r, y: rect.maxY),
                           control: CGPoint(x: rect.minX + ear, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX - ear - r, y: rect.maxY))
            p.addQuadCurve(to: CGPoint(x: rect.maxX - ear, y: rect.maxY - r),
                           control: CGPoint(x: rect.maxX - ear, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX - ear, y: rect.minY + ear))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                           control: CGPoint(x: rect.maxX - ear, y: rect.minY))
            p.closeSubpath()
        } else {
            p.addRoundedRect(in: rect, cornerSize: CGSize(width: r, height: r), style: .continuous)
        }
        return p
    }
}

// MARK: - Formatierung

enum IslandFormat {
    @MainActor
    static func value(_ value: IslandValue, engine: StatsEngine) -> String? {
        switch value {
        case .none:
            return nil
        case .network:
            return SpeedFormat.speed(engine.state(for: .network).read, units: engine.units, compact: true)
        case .disk:
            let s = engine.state(for: .internalDrives)
            return SpeedFormat.speed(s.read + s.write, units: engine.units, compact: true)
        case .cpuTemp:
            return engine.system.cpuTemp.map { "\(Int($0.rounded())) °C" }
        case .battery:
            return engine.battery.map { "\($0.percent) %" }
        }
    }

    @MainActor
    static func symbol(_ value: IslandValue, engine: StatsEngine) -> String {
        switch value {
        case .none: ""
        case .network: "arrow.down"
        case .disk: "internaldrive"
        case .cpuTemp: "thermometer.medium"
        case .battery: engine.battery.map(BatteryCard.symbol(for:)) ?? "battery.100percent"
        }
    }

    @MainActor
    static func tint(_ value: IslandValue, engine: StatsEngine) -> Color {
        switch value {
        case .none: .clear
        case .network: SpeedGroup.network.tint
        case .disk: SpeedGroup.internalDrives.tint
        case .cpuTemp: SystemCard.tint
        case .battery: engine.battery.map(BatteryCard.color(for:)) ?? .green
        }
    }
}

// MARK: - Vorschau beim Darüberfahren

private struct IslandPeekRow: View {
    let engine: StatsEngine

    var body: some View {
        HStack(spacing: 14) {
            stat("internaldrive", SpeedGroup.internalDrives.tint,
                 SpeedFormat.speed(engine.state(for: .internalDrives).read + engine.state(for: .internalDrives).write,
                                   units: engine.units, compact: true))
            stat("arrow.down", SpeedGroup.network.tint,
                 SpeedFormat.speed(engine.state(for: .network).read, units: engine.units, compact: true))
            stat("arrow.up", SpeedGroup.network.tint,
                 SpeedFormat.speed(engine.state(for: .network).write, units: engine.units, compact: true))
            stat("cpu", SystemCard.tint,
                 engine.system.cpuUsage.map { "\(Int(($0 * 100).rounded())) %" } ?? "–")
            if let battery = engine.battery {
                stat(BatteryCard.symbol(for: battery), BatteryCard.color(for: battery), "\(battery.percent) %")
            }
            if let track = NowPlaying.shared.track {
                stat(track.isPlaying ? "play.fill" : "pause.fill", .pink, track.title)
                    .frame(maxWidth: 120)
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
    }

    private func stat(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .lineLimit(1)
        }
    }
}

// MARK: - Tabs

private struct IslandLiveTab: View {
    let engine: StatsEngine

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            group(.internalDrives, "L", "S")
            group(.externalDrives, "L", "S")
            group(.network, "↓", "↑")
            system
        }
    }

    private func group(_ g: SpeedGroup, _ a: String, _ b: String) -> some View {
        let s = engine.state(for: g)
        return tile(symbol: g.symbol, tint: g.tint, title: g.title) {
            line(a, SpeedFormat.speed(s.read, units: engine.units), g.tint)
            line(b, SpeedFormat.speed(s.write, units: engine.units), g.tint.opacity(0.7))
        }
    }

    private var system: some View {
        tile(symbol: "cpu", tint: SystemCard.tint, title: "System") {
            line("CPU", engine.system.cpuUsage.map { "\(Int(($0 * 100).rounded())) %" } ?? "–", SystemCard.tint)
            line("°C", engine.system.cpuTemp.map { "\(Int($0.rounded()))" } ?? "–", SystemCard.tint.opacity(0.7))
        }
    }

    private func tile<C: View>(symbol: String, tint: Color, title: String,
                               @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: .rect(cornerRadius: 12))
    }

    private func line(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

private struct IslandShelfTab: View {
    @Bindable var shelf: FileShelf
    let isDropTarget: Bool

    var body: some View {
        Group {
            if shelf.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Dateien hierher ziehen")
                        .font(.callout.weight(.semibold))
                    Text("Sie bleiben in der Ablage, bis du sie weiterziehst.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(shelf.items) { item in
                            IslandShelfItem(item: item, shelf: shelf)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(isDropTarget ? 0.8 : 0.18),
                              style: StrokeStyle(lineWidth: isDropTarget ? 2 : 1, dash: [6, 5]))
        }
    }
}

private struct IslandShelfItem: View {
    let item: ShelfItem
    let shelf: FileShelf

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 52, height: 52)
                .opacity(item.missing ? 0.4 : 1)
            Text(item.name)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 76)
        }
        .padding(6)
        .contentShape(.rect)
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { shelf.open(item) }
        .contextMenu {
            Button("Öffnen") { shelf.open(item) }
            Button("Im Finder zeigen") { shelf.reveal(item) }
            Divider()
            Button("Aus der Ablage entfernen") { shelf.remove(item) }
        }
        .help("Ziehen zum Weitergeben · Doppelklick öffnet")
    }
}

private struct IslandMusicTab: View {
    @Bindable var player: NowPlaying

    var body: some View {
        if let track = player.track {
            HStack(spacing: 16) {
                Group {
                    if let artwork = player.artwork {
                        Image(nsImage: artwork).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color.white.opacity(0.08)
                            Image(systemName: "music.note").font(.system(size: 28))
                        }
                    }
                }
                .frame(width: 96, height: 96)
                .clipShape(.rect(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("\(track.album) · \(track.player.title)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    HStack(spacing: 22) {
                        control("backward.fill") { player.previous() }
                        control(track.isPlaying ? "pause.fill" : "play.fill", big: true) { player.playPause() }
                        control("forward.fill") { player.next() }
                    }
                    .padding(.top, 8)
                }
                Spacer(minLength: 0)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(.system(size: 22, weight: .semibold))
                Text(player.permissionDenied
                     ? "floosh darf Musik/Spotify nicht steuern"
                     : "Gerade läuft nichts in Musik oder Spotify")
                    .font(.callout.weight(.semibold))
                Text(player.permissionDenied
                     ? "Systemeinstellungen → Datenschutz & Sicherheit → Automation → floosh"
                     : "Browser-Wiedergabe kann macOS fremden Apps nicht mehr zeigen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func control(_ symbol: String, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: big ? 22 : 15, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct IslandBatteryTab: View {
    let engine: StatsEngine

    var body: some View {
        if let b = engine.battery {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(b.percent) %")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(BatteryCard.color(for: b))
                    Text(BatteryCard.status(for: b))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let time = BatteryCard.timeLine(for: b) {
                        Text(time)
                            .font(.caption)
                            .monospacedDigit()
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    if b.isPluggedIn {
                        flow("Netzteil", b.adapterWatts.map { "\($0) W max" } ?? "–")
                        flow("Mac braucht", b.systemLoadWatts.map { BatteryCard.format($0) + " W" } ?? "–")
                        flow("in den Akku", BatteryCard.format(max(b.batteryWatts, 0)) + " W")
                    } else {
                        flow("Verbrauch", BatteryCard.format(abs(b.batteryWatts)) + " W")
                    }
                    if let hint = BatteryCard.hint(for: b) {
                        Text(hint)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func flow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
    }
}

private struct IslandToolsTab: View {
    let engine: StatsEngine
    @Bindable var awake: KeepAwake = .shared
    @Bindable var fans: FanService = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                tool(awake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer",
                     awake.isActive ? (awake.remainingText ?? "Wach") : "Wachhalten",
                     active: awake.isActive) { awake.toggle() }
                tool("sparkles", "Reinigen") {
                    IslandController.shared.setMode(.idle)
                    CleanScreen.shared.start()
                }
                tool("menubar.arrow.down.rectangle", "Dropdown") {
                    IslandController.shared.setMode(.idle)
                    MenuBarController.shared?.open()
                }
            }
            if !engine.system.fans.isEmpty {
                HStack(spacing: 10) {
                    Label("Lüfter", systemImage: "fan")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { fans.mode },
                        set: { mode in
                            switch mode {
                            case .auto: fans.setAuto()
                            case .manual: fans.refreshHelperState(); fans.setManual()
                            case .curve: fans.refreshHelperState(); fans.setCurve()
                            }
                        })) {
                        Text("Auto").tag(FanService.Mode.auto)
                        Text("Manuell").tag(FanService.Mode.manual)
                        Text("Kurve").tag(FanService.Mode.curve)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tool(_ symbol: String, _ title: String, active: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(active ? SystemCard.tint.opacity(0.35) : .white.opacity(0.08),
                        in: .rect(cornerRadius: 12))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
