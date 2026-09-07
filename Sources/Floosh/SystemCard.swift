import SwiftUI

/// Glas-Karte für CPU & GPU: Auslastung, Die-Temperaturen und Lüftersteuerung
/// (Auto / Manuell mit Schieberegler und Favoriten / Temperaturkurve).
struct SystemCard: View {
    let engine: StatsEngine
    @Bindable var fans: FanService
    @Bindable var awake: KeepAwake = .shared
    @Bindable var clean: CleanScreen = .shared
    var tools: ToolSettings = .shared

    static let tint = Color(red: 0.68, green: 0.48, blue: 1.0) // Violett

    private var size: CardSize { engine.cardSize }

    var body: some View {
        VStack(alignment: .leading, spacing: size.spacing) {
            header
            usageRows
            if !engine.system.fans.isEmpty {
                fanSection
            }
            if tools.showTools {
                toolRow
            }
        }
        // Im Raster füllt die Karte die Zeilenhöhe (Glas bis zum Rand)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(size.padding)
        .cardGlass(cornerRadius: size.cornerRadius)
        .onAppear { fans.refreshHelperState() }
    }

    // MARK: Werkzeuge

    /// Wachhalten und Bildschirm reinigen — zwei Knöpfe, wie bei den
    /// Lüfter-Modi darüber.
    private var toolRow: some View {
        HStack(spacing: 6) {
            Button {
                awake.toggle()
            } label: {
                toolLabel(symbol: awake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer",
                          text: awake.isActive ? (awake.remainingText ?? "wach") : "Wachhalten",
                          active: awake.isActive)
            }
            .buttonStyle(.plain)
            .featureGated(.keepAwake)
            .help(awake.isActive
                  ? "Wachhalten beenden — der Bildschirm darf wieder schlafen"
                  : "Bildschirm wachhalten (\(awake.duration.title))")

            Button {
                clean.start()
            } label: {
                toolLabel(symbol: "sparkles", text: "Reinigen", active: false)
            }
            .buttonStyle(.plain)
            .featureGated(.cleanScreen)
            .help("Bildschirm für \(clean.seconds) s abdunkeln und Eingaben sperren")
        }
    }

    private func toolLabel(symbol: String, text: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: size.glyphFont))
            Text(text)
                .font(.caption)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(active ? Self.tint.opacity(0.28) : Color.primary.opacity(0.07),
                    in: .rect(cornerRadius: 8))
        .foregroundStyle(active ? Self.tint : .primary)
        .contentShape(.rect(cornerRadius: 8))
    }

    // MARK: Kopfzeile

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            CardIcon(symbol: "cpu", tint: Self.tint, size: size)

            VStack(alignment: .leading, spacing: 1) {
                Text("System")
                    .font(size.titleFont)
                Text(engine.chipName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                tempBadge(label: "CPU", temp: engine.system.cpuTemp)
                tempBadge(label: "GPU", temp: engine.system.gpuTemp)
            }
        }
    }

    private func tempBadge(label: String, temp: Double?) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: size.glyphFont, weight: .bold, design: .rounded))
                .foregroundStyle(Self.tint.opacity(label == "GPU" ? 0.55 : 1))
            Text(temp.map { "\(Int($0.rounded())) °C" } ?? "–")
                .font(.system(size: size.valueFont, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
    }

    // MARK: Auslastung

    private var usageRows: some View {
        VStack(spacing: size == .large ? 8 : 6) {
            usageRow(label: "CPU", value: engine.system.cpuUsage, color: Self.tint)
            usageRow(label: "GPU", value: engine.system.gpuUsage, color: Self.tint.opacity(0.55))
        }
    }

    private func usageRow(label: String, value: Double?, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(color)
                        .frame(width: max(6, geo.size.width * (value ?? 0)))
                        .animation(.snappy(duration: 0.3), value: value ?? 0)
                }
            }
            .frame(height: size == .large ? 8 : 6)
            Text(value.map { "\(Int(($0 * 100).rounded())) %" } ?? "–")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
    }

    // MARK: Lüfter

    private var fanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Bei der kleinen Kachel passt der Modus-Wahlschalter nicht mehr
            // neben die Drehzahlen — dann in eine eigene Zeile.
            if size == .small {
                fanSummaryRow
                modePicker.frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 8) {
                    fanSummaryRow
                    Spacer(minLength: 6)
                    modePicker.frame(width: size == .large ? 176 : 156)
                }
            }

            switch fans.mode {
            case .auto:
                EmptyView()
            case .manual:
                if fans.helperState == .ready { manualControls } else { helperPrompt }
            case .curve:
                if fans.helperState == .ready { curveStatus } else { helperPrompt }
            }

            if let error = fans.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.top, 2)
    }

    private var fanSummaryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "fan")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(fanSummary)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private var fanSummary: String {
        let rpms = engine.system.fans.map { "\(Int($0.rpm.rounded()))" }
        return "\(rpms.joined(separator: " / ")) U/min"
    }

    private var modePicker: some View {
        Picker("", selection: modeBinding) {
            Text("Auto").tag(FanService.Mode.auto)
            Text("Manuell").tag(FanService.Mode.manual)
            Text("Kurve").tag(FanService.Mode.curve)
        }
        .pickerStyle(.segmented)
        .controlSize(.mini)
        .labelsHidden()
    }

    private var modeBinding: Binding<FanService.Mode> {
        Binding {
            fans.mode
        } set: { newMode in
            switch newMode {
            case .auto:
                fans.setAuto()
            case .manual:
                fans.refreshHelperState()
                fans.setManual()
            case .curve:
                fans.refreshHelperState()
                fans.setCurve()
            }
        }
    }

    private var manualControls: some View {
        HStack(spacing: 8) {
            Slider(value: $fans.percent, in: 0...100, step: 5) { editing in
                if !editing { fans.setManual() }
            }
            Text("\(Int(fans.percent)) %")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)

            favoriteButton(value: $fans.favorite1)
            favoriteButton(value: $fans.favorite2)
        }
    }

    /// Kurven-Modus: Mini-Diagramm mit Marker plus Sensorwert und Zieldrehzahl.
    private var curveStatus: some View {
        HStack(spacing: 10) {
            FanCurveChart(curve: fans.curve, temp: fans.curveTemp, target: fans.curveTarget,
                          compact: true, tint: Self.tint)
                .frame(height: max(36, size.chartHeight * 0.85))

            VStack(alignment: .trailing, spacing: 0) {
                if let temp = fans.curveTemp, let target = fans.curveTarget {
                    Text(fans.curve.source.sensorLabel)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                    Text("\(Int(temp.rounded())) °C")
                        .font(.system(size: size.valueFont, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("Ziel \(Int(target)) %")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("Kein\nSensor")
                        .font(.caption2)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.orange)
                }
            }
            .frame(minWidth: 52, alignment: .trailing)
        }
        .help("Die Kurve lässt sich in den Einstellungen → Lüfter bearbeiten")
    }

    /// Kleiner Favoriten-Knopf: Klick übernimmt die Drehzahl, Rechtsklick
    /// speichert den aktuellen Regler-Wert als neuen Favoriten.
    private func favoriteButton(value: Binding<Double>) -> some View {
        Button {
            fans.setManual(percent: value.wrappedValue)
        } label: {
            Text("\(Int(value.wrappedValue))%")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 26)
        }
        .compatGlassButton()
        .controlSize(.small)
        .contextMenu {
            Button("Aktuellen Wert (\(Int(fans.percent)) %) als Favorit speichern") {
                value.wrappedValue = fans.percent
            }
        }
        .help("Klick: übernehmen · Rechtsklick: aktuellen Wert speichern")
    }

    private var helperPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch fans.helperState {
            case .needsRegistration:
                Text("Die Lüftersteuerung braucht einmalig einen System-Helfer.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Helfer aktivieren …") { fans.registerHelper() }
                    .compatGlassButton()
                    .controlSize(.small)
            case .needsApproval:
                Text("Bitte floosh in Systemeinstellungen → Anmeldeobjekte erlauben.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Systemeinstellungen öffnen …") { fans.openApprovalSettings() }
                    .compatGlassButton()
                    .controlSize(.small)
            case .unavailable(let reason):
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            case .ready:
                EmptyView()
            }
        }
    }
}
