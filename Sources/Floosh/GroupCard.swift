import SwiftUI
import Charts

/// Eine Glas-Karte pro Gruppe: große Live-Werte, Verlaufs-Diagramm, optionale Details.
struct GroupCard: View {
    let engine: StatsEngine
    let group: SpeedGroup

    private var isSelected: Bool { engine.selectedGroup == group }

    var body: some View {
        let state = engine.state(for: group)

        Button {
            withAnimation(.snappy(duration: 0.25)) { engine.selectedGroup = group }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                // Kopfzeile: Symbol, Titel, große Zahlen
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: group.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(group.tint)
                        .frame(width: 34, height: 34)
                        .background(group.tint.opacity(0.16), in: .circle)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.title)
                            .font(.system(.body, design: .rounded, weight: .semibold))
                        Text(subtitle(state))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 1) {
                        speedRow(glyph: group.readGlyph,
                                 value: state.read,
                                 color: group.tint)
                        speedRow(glyph: group.writeGlyph,
                                 value: state.write,
                                 color: group.tint.opacity(0.55))
                    }
                }

                SpeedChart(engine: engine, group: group)
                    .frame(height: 46)

                if engine.showPeaks {
                    peaksRow
                }

                if engine.showDevices, !state.devices.isEmpty {
                    deviceList(state.devices)
                }
            }
            .padding(12)
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .cardGlass(tint: isSelected ? group.tint.opacity(0.22) : nil, interactive: true)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(group.tint.opacity(0.55), lineWidth: 1.5)
            }
        }
        .help("In der Menüleiste anzeigen: \(group.title)")
    }

    private func subtitle(_ state: StatsEngine.GroupState) -> String {
        let count = state.devices.count
        if count == 0 {
            return group == .network ? "Keine aktiven Interfaces" : "Keine Laufwerke"
        }
        return "\(count) \(count == 1 ? group.deviceNoun : group.deviceNounPlural)"
    }

    private func speedRow(glyph: String, value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(glyph)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(SpeedFormat.speed(value, units: engine.units))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }

    private var peaksRow: some View {
        let peak = engine.windowMax(for: group)
        return HStack(spacing: 10) {
            Text("Spitze")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            HStack(spacing: 3) {
                Text(group.readGlyph).bold()
                Text(SpeedFormat.speed(peak.read, units: engine.units))
            }
            .foregroundStyle(group.tint)
            HStack(spacing: 3) {
                Text(group.writeGlyph).bold()
                Text(SpeedFormat.speed(peak.write, units: engine.units))
            }
            .foregroundStyle(group.tint.opacity(0.55))
            Spacer()
        }
        .font(.caption2)
        .monospacedDigit()
    }

    private func deviceList(_ devices: [DeviceSpeed]) -> some View {
        let visible = Array(devices.prefix(4))
        let hidden = devices.count - visible.count
        return VStack(spacing: 4) {
            ForEach(visible) { device in
                HStack(spacing: 6) {
                    Text(device.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("\(group.readGlyph) \(SpeedFormat.speed(device.read, units: engine.units, compact: true))")
                        .foregroundStyle(group.tint)
                    Text("\(group.writeGlyph) \(SpeedFormat.speed(device.write, units: engine.units, compact: true))")
                        .foregroundStyle(group.tint.opacity(0.65))
                }
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
            }
            if hidden > 0 {
                Text("+ \(hidden) weitere")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Diagramm

private struct ChartPoint: Identifiable {
    let id: String
    let date: Date
    let channel: String
    let value: Double
}

struct SpeedChart: View {
    let engine: StatsEngine
    let group: SpeedGroup

    var body: some View {
        let end = engine.lastSampleDate
        let start = end.addingTimeInterval(-engine.chartWindow)
        let samples = engine.state(for: group).samples.filter { $0.date >= start }
        let peak = engine.windowMax(for: group)
        let yMax = max(peak.read, peak.write, 1_000_000) * 1.2

        let points = samples.flatMap { s in
            [
                ChartPoint(id: "r\(s.date.timeIntervalSinceReferenceDate)", date: s.date, channel: "read", value: s.read),
                ChartPoint(id: "w\(s.date.timeIntervalSinceReferenceDate)", date: s.date, channel: "write", value: s.write),
            ]
        }

        Chart(points) { point in
            AreaMark(
                x: .value("Zeit", point.date),
                y: .value("Rate", point.value),
                series: .value("Kanal", point.channel)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(gradient(for: point.channel))

            LineMark(
                x: .value("Zeit", point.date),
                y: .value("Rate", point.value),
                series: .value("Kanal", point.channel)
            )
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .foregroundStyle(color(for: point.channel))
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...yMax)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .clipShape(.rect(cornerRadius: 8))
    }

    private func color(for channel: String) -> Color {
        channel == "read" ? group.tint : group.tint.opacity(0.5)
    }

    private func gradient(for channel: String) -> LinearGradient {
        let base = color(for: channel)
        return LinearGradient(
            colors: [base.opacity(0.35), base.opacity(0.02)],
            startPoint: .top, endPoint: .bottom
        )
    }
}
