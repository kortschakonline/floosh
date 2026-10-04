import SwiftUI

/// Glas-Karte für den Akku (nur Macs mit Akku): Ladestand mit 80-%-Marke,
/// wohin die Leistung des Netzteils geht, Zeiten bis 80 % / voll / leer und
/// der Zustand des Akkus.
///
/// Der Kern ist der Leistungsfluss: Netzteil → Mac → Akku. Lädt es „ewig",
/// sieht man sofort, warum — z. B. ein 45-W-Netzteil, das zusätzlich ein
/// Telefon versorgt, während der Mac selbst 25 W braucht.
struct BatteryCard: View {
    let engine: StatsEngine

    private var size: CardSize { engine.cardSize }

    var body: some View {
        VStack(alignment: .leading, spacing: size.spacing) {
            if let battery = engine.battery {
                header(battery)
                ChargeBar(battery: battery, color: Self.color(for: battery),
                          height: size == .large ? 12 : 10)
                if battery.isPluggedIn {
                    powerFlow(battery)
                } else {
                    flowValue(label: "Verbrauch gerade", watts: abs(battery.batteryWatts), suffix: " W")
                }
                if let hint = Self.hint(for: battery) {
                    hintRow(hint)
                }
                footer(battery)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(size.padding)
        .cardGlass(cornerRadius: size.cornerRadius)
    }

    // MARK: Kopfzeile

    private func header(_ b: BatterySampler.Reading) -> some View {
        HStack(alignment: .center, spacing: 10) {
            CardIcon(symbol: Self.symbol(for: b), tint: Self.color(for: b), size: size)

            VStack(alignment: .leading, spacing: 1) {
                Text("Akku")
                    .font(size.titleFont)
                Text(Self.status(for: b))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(b.percent) %")
                    .font(.system(size: size.valueFont + 2, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if let time = Self.timeLine(for: b) {
                    Text(time)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Leistungsfluss

    /// Netzteil → Mac → Akku, als drei Spalten mit Pfeilen dazwischen.
    private func powerFlow(_ b: BatterySampler.Reading) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            flowValue(label: "Netzteil", watts: b.adapterWatts.map(Double.init), suffix: " W max")
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
            flowValue(label: "Mac braucht", watts: b.systemLoadWatts, suffix: " W")
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
            flowValue(label: "in den Akku", watts: max(b.batteryWatts, 0), suffix: " W",
                      tint: b.isCharging ? Self.color(for: b) : nil)
        }
        .help("Was das Netzteil höchstens liefern kann, was der Mac gerade selbst verbraucht und was davon im Akku ankommt")
    }

    private func flowValue(label: String, watts: Double?, suffix: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(watts.map { Self.format($0) + suffix } ?? "–")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hintRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.orange)
    }

    private func footer(_ b: BatterySampler.Reading) -> some View {
        HStack(spacing: 10) {
            if let health = b.health {
                Label("Zustand \(Int((health * 100).rounded())) %", systemImage: "heart")
            }
            if let cycles = b.cycleCount {
                Label("\(cycles) Zyklen", systemImage: "arrow.triangle.2.circlepath")
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }

    // MARK: Einordnung

    /// Ladeklasse nach Leistung in den Akku — Farbe und Tempo der Animation.
    enum ChargeSpeed {
        case slow, normal, fast

        init(watts: Double) {
            switch watts {
            case ..<8: self = .slow
            case ..<30: self = .normal
            default: self = .fast
            }
        }

        var title: String {
            switch self {
            case .slow: "langsam"
            case .normal: "normal"
            case .fast: "schnell"
            }
        }
    }

    static func color(for b: BatterySampler.Reading) -> Color {
        if b.isCharging {
            switch ChargeSpeed(watts: b.batteryWatts) {
            case .slow: return .orange
            case .normal: return .green
            case .fast: return .cyan
            }
        }
        if b.isPluggedIn { return .green }
        switch b.percent {
        case ..<15: return .red
        case ..<30: return .orange
        default: return .green
        }
    }

    static func symbol(for b: BatterySampler.Reading) -> String {
        if b.isCharging || b.isPluggedIn { return "battery.100percent.bolt" }
        switch b.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    static func status(for b: BatterySampler.Reading) -> String {
        if b.isCharging {
            let speed = ChargeSpeed(watts: b.batteryWatts).title
            if let watts = b.adapterWatts { return "Lädt \(speed) · \(watts) W" }
            return "Lädt \(speed)"
        }
        if b.isPluggedIn {
            if b.isFull || b.percent >= 100 { return "Voll · am Netzteil" }
            return "Am Netzteil · lädt gerade nicht"
        }
        return "Akkubetrieb"
    }

    static func timeLine(for b: BatterySampler.Reading) -> String? {
        if b.isCharging {
            if let to80 = b.minutesTo80 { return "bis 80 %: \(duration(to80))" }
            if let full = b.minutesToFull { return "bis voll: \(duration(full))" }
            return "Zeit wird berechnet …"
        }
        if !b.isPluggedIn {
            if let empty = b.minutesToEmpty { return "noch \(duration(empty))" }
            return "Zeit wird berechnet …"
        }
        return nil
    }

    /// Erklärt, warum es langsam oder gar nicht lädt — der eigentliche Grund
    /// für diese Kachel.
    static func hint(for b: BatterySampler.Reading) -> String? {
        guard b.isPluggedIn, !(b.isFull || b.percent >= 100) else { return nil }
        if !b.isCharging {
            if b.notChargingReason != 0 {
                return "macOS hält das Laden gerade an — etwa durch optimiertes Laden (Pause bei 80 %) oder weil der Akku zu warm ist."
            }
            return nil
        }
        let intoBattery = max(b.batteryWatts, 0)
        guard ChargeSpeed(watts: intoBattery) == .slow else { return nil }
        let load = b.systemLoadWatts.map { "der Mac selbst braucht \(format($0)) W" } ?? "der Mac braucht selbst viel"
        if let adapter = b.adapterWatts {
            if let incoming = b.systemInWatts, incoming < Double(adapter) * 0.6 {
                return "Vom \(adapter)-W-Netzteil kommen nur \(format(incoming)) W an (Kabel, Hub oder ein zweites Gerät am Netzteil?) — \(load), für den Akku bleiben \(format(intoBattery)) W. Das ist kein Akku-Defekt."
            }
            return "Das \(adapter)-W-Netzteil reicht knapp: \(load), für den Akku bleiben nur \(format(intoBattery)) W. Ein stärkeres Netzteil lädt schneller — der Akku ist nicht defekt."
        }
        return "Lädt langsam: \(load), für den Akku bleiben nur \(format(intoBattery)) W."
    }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60):\(String(format: "%02d", minutes % 60)) h" : "\(minutes) min"
    }

    static func format(_ watts: Double) -> String {
        watts < 10 ? String(format: "%.1f", watts).replacingOccurrences(of: ".", with: ",")
                   : "\(Int(watts.rounded()))"
    }
}

// MARK: - Ladebalken

/// Ladestand als Kapsel mit 80-%-Marke. Beim Laden läuft ein Lichtschimmer
/// durch — je mehr Watt im Akku ankommen, desto schneller.
private struct ChargeBar: View {
    let battery: BatterySampler.Reading
    let color: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fill = max(height, width * CGFloat(battery.percent) / 100)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color.gradient)
                    .frame(width: fill)
                    .overlay(alignment: .leading) {
                        if battery.isCharging, !DebugSnapshot.isActive {
                            Shimmer(width: fill, speed: shimmerSpeed)
                                .clipShape(Capsule())
                        }
                    }
                    .animation(.snappy(duration: 0.4), value: battery.percent)
                // 80-%-Marke: optimiertes Laden pausiert hier
                Rectangle()
                    .fill(.primary.opacity(0.45))
                    .frame(width: 1.5, height: height + 4)
                    .offset(x: width * 0.8)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Ladestand \(battery.percent) Prozent")
    }

    /// Sekunden pro Durchlauf: schnell laden = schneller Schimmer.
    private var shimmerSpeed: Double {
        switch BatteryCard.ChargeSpeed(watts: battery.batteryWatts) {
        case .slow: 3.2
        case .normal: 1.9
        case .fast: 1.0
        }
    }
}

private struct Shimmer: View {
    let width: CGFloat
    let speed: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (t / speed).truncatingRemainder(dividingBy: 1)
            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: max(24, width * 0.35))
                .offset(x: -width * 0.35 + phase * width * 1.35)
        }
        .allowsHitTesting(false)
    }
}
