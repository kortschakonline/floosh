import SwiftUI

/// Glas-Karte für CPU & GPU: Auslastung, Die-Temperaturen und Lüftersteuerung
/// (Auto/Manuell mit Schieberegler und zwei Drehzahl-Favoriten).
struct SystemCard: View {
    let engine: StatsEngine
    @Bindable var fans: FanService

    private static let tint = Color(red: 0.68, green: 0.48, blue: 1.0) // Violett

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            usageRows
            if !engine.system.fans.isEmpty {
                fanSection
            }
        }
        .padding(12)
        .cardGlass(.regular)
        .onAppear { fans.refreshHelperState() }
    }

    // MARK: Kopfzeile

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "cpu")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Self.tint)
                .frame(width: 34, height: 34)
                .background(Self.tint.opacity(0.16), in: .circle)

            VStack(alignment: .leading, spacing: 1) {
                Text("System")
                    .font(.system(.body, design: .rounded, weight: .semibold))
                Text(engine.chipName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Self.tint.opacity(label == "GPU" ? 0.55 : 1))
            Text(temp.map { "\(Int($0.rounded())) °C" } ?? "–")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
    }

    // MARK: Auslastung

    private var usageRows: some View {
        VStack(spacing: 6) {
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
            .frame(height: 6)
            Text(value.map { "\(Int(($0 * 100).rounded())) %" } ?? "–")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
    }

    // MARK: Lüfter

    private var fanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "fan")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(fanSummary)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: modeBinding) {
                    Text("Auto").tag(FanService.Mode.auto)
                    Text("Manuell").tag(FanService.Mode.manual)
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 124)
                .labelsHidden()
            }

            if fans.mode == .manual {
                if fans.helperState == .ready {
                    manualControls
                } else {
                    helperPrompt
                }
            }

            if let error = fans.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.top, 2)
    }

    private var fanSummary: String {
        let rpms = engine.system.fans.map { "\(Int($0.rpm.rounded()))" }
        return "\(rpms.joined(separator: " / ")) U/min"
    }

    private var modeBinding: Binding<FanService.Mode> {
        Binding {
            fans.mode
        } set: { newMode in
            switch newMode {
            case .auto: fans.setAuto()
            case .manual:
                fans.refreshHelperState()
                fans.setManual()
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
        .buttonStyle(.glass)
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
                Text("Die manuelle Lüftersteuerung braucht einmalig einen System-Helfer.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Helfer aktivieren …") { fans.registerHelper() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            case .needsApproval:
                Text("Bitte floosh in Systemeinstellungen → Anmeldeobjekte erlauben.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Systemeinstellungen öffnen …") { fans.openApprovalSettings() }
                    .buttonStyle(.glass)
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
