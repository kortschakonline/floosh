import SwiftUI
import Charts

/// Temperaturabhängige Lüfterkurve: Stützpunkte (°C → %) mit linearer
/// Interpolation dazwischen; unterhalb des ersten und oberhalb des letzten
/// Punkts gilt dessen Wert.
struct FanCurve: Codable, Equatable {

    enum Source: String, Codable, CaseIterable, Identifiable {
        case cpu, gpu, max
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cpu: "CPU"
            case .gpu: "GPU"
            case .max: "Höchste"
            }
        }
        /// Kurzform für die Karte im Dropdown.
        var sensorLabel: String {
            switch self {
            case .cpu: "CPU"
            case .gpu: "GPU"
            case .max: "CPU/GPU"
            }
        }
    }

    struct Point: Codable, Equatable, Identifiable {
        var id = UUID()
        var temp: Double      // °C
        var percent: Double   // 0…100
    }

    static let tempRange: ClosedRange<Double> = 30...100
    static let maxPoints = 8

    var source: Source = .max
    var points: [Point]

    static let standard = FanCurve(points: [
        Point(temp: 50, percent: 0),
        Point(temp: 65, percent: 30),
        Point(temp: 80, percent: 70),
        Point(temp: 90, percent: 100),
    ])

    /// Sensorwert je nach Quelle; nil, wenn der gewünschte Sensor fehlt.
    func temperature(cpu: Double?, gpu: Double?) -> Double? {
        switch source {
        case .cpu: cpu
        case .gpu: gpu
        case .max:
            switch (cpu, gpu) {
            case let (c?, g?): max(c, g)
            case let (c?, nil): c
            case let (nil, g?): g
            default: nil
            }
        }
    }

    /// Ziel-Prozent für eine Temperatur.
    func percent(at temp: Double) -> Double {
        let sorted = points.sorted { $0.temp < $1.temp }
        guard let first = sorted.first, let last = sorted.last else { return 0 }
        if temp <= first.temp { return first.percent }
        if temp >= last.temp { return last.percent }
        for (a, b) in zip(sorted, sorted.dropFirst()) where temp >= a.temp && temp <= b.temp {
            let span = b.temp - a.temp
            guard span > 0 else { return max(a.percent, b.percent) }
            return a.percent + (temp - a.temp) / span * (b.percent - a.percent)
        }
        return last.percent
    }

    /// Nach dem Bearbeiten: Punkte wieder nach Temperatur ordnen.
    mutating func normalize() {
        points.sort { $0.temp < $1.temp }
    }

    /// Neuen Punkt in die größte Lücke setzen (oder hinter den letzten).
    mutating func addPoint() {
        guard points.count < Self.maxPoints else { return }
        normalize()
        var best: (gap: Double, index: Int, point: Point)?
        for (i, (a, b)) in zip(points, points.dropFirst()).enumerated() {
            let gap = b.temp - a.temp
            if gap >= 2, gap > (best?.gap ?? 0) {
                best = (gap, i + 1, Point(temp: ((a.temp + b.temp) / 2).rounded(),
                                          percent: ((a.percent + b.percent) / 2 / 5).rounded() * 5))
            }
        }
        if let best {
            points.insert(best.point, at: best.index)
        } else if let last = points.last, last.temp + 5 <= Self.tempRange.upperBound {
            points.append(Point(temp: last.temp + 5, percent: min(100, last.percent + 10)))
        }
    }
}

// MARK: - Diagramm

/// Kurven-Diagramm mit Marker für die aktuelle (geglättete) Temperatur.
/// `compact` für die System-Karte im Dropdown: ohne Achsen, feinere Linie.
struct FanCurveChart: View {
    let curve: FanCurve
    let temp: Double?
    let target: Double?
    var compact = false
    var tint: Color = .accentColor

    private struct LinePoint: Identifiable {
        let id: Int
        let temp: Double
        let percent: Double
    }

    var body: some View {
        let sorted = curve.points.sorted { $0.temp < $1.temp }
        let range = FanCurve.tempRange
        let line = extended(sorted, to: range)

        Chart {
            ForEach(line) { p in
                AreaMark(x: .value("°C", p.temp), y: .value("%", p.percent))
                    .foregroundStyle(
                        LinearGradient(colors: [tint.opacity(0.3), tint.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                LineMark(x: .value("°C", p.temp), y: .value("%", p.percent))
                    .lineStyle(StrokeStyle(lineWidth: compact ? 1.5 : 2, lineCap: .round))
                    .foregroundStyle(tint)
            }
            ForEach(sorted) { p in
                PointMark(x: .value("°C", p.temp), y: .value("%", p.percent))
                    .symbolSize(compact ? 16 : 44)
                    .foregroundStyle(tint)
            }
            if let temp, let target {
                let x = min(max(temp, range.lowerBound), range.upperBound)
                RuleMark(x: .value("°C", x))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.secondary.opacity(0.5))
                PointMark(x: .value("°C", x), y: .value("%", target))
                    .symbolSize(compact ? 34 : 80)
                    .foregroundStyle(.primary)
            }
        }
        .chartXScale(domain: range)
        .chartYScale(domain: 0...100)
        .chartLegend(.hidden)
        .chartXAxis {
            if compact {
                AxisMarks(values: [Double]()) { _ in }
            } else {
                AxisMarks(values: .stride(by: 10.0)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Int(v)) °C").font(.caption2)
                        }
                    }
                }
            }
        }
        .chartYAxis {
            if compact {
                AxisMarks(values: [Double]()) { _ in }
            } else {
                AxisMarks(values: [0.0, 50, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Int(v)) %").font(.caption2)
                        }
                    }
                }
            }
        }
        // Nur die Kompaktform beschneiden — im Editor würde der Clip das
        // oberste Achsen-Label („100 %") abschneiden.
        .clipShape(.rect(cornerRadius: compact ? 6 : 0))
    }

    /// Linie bis an die Diagrammränder verlängern — außerhalb der Stützpunkte
    /// gilt der jeweilige Randwert.
    private func extended(_ sorted: [FanCurve.Point], to range: ClosedRange<Double>) -> [LinePoint] {
        var pts: [LinePoint] = []
        if let first = sorted.first, first.temp > range.lowerBound {
            pts.append(LinePoint(id: -1, temp: range.lowerBound, percent: first.percent))
        }
        for (i, p) in sorted.enumerated() {
            pts.append(LinePoint(id: i, temp: p.temp, percent: p.percent))
        }
        if let last = sorted.last, last.temp < range.upperBound {
            pts.append(LinePoint(id: sorted.count, temp: range.upperBound, percent: last.percent))
        }
        return pts
    }
}
