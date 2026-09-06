import SwiftUI
import AppKit

/// Vorlage für das Menüleisten-Bild — alles, was der Renderer braucht, ohne
/// selbst am Engine zu hängen (so kann der Snapshot-Hook Varianten bauen).
struct MenuLabelSpec {
    var group: SpeedGroup
    var labelStyle: MenuLabelStyle
    var iconStyle: MenuIconStyle
    /// Zahlen in Gruppenfarbe — nur beim farbigen Symbol möglich (Template-
    /// Bilder sind einfarbig).
    var tintText = false
    var singleLine = ""
    var readLine = ""
    var writeLine = ""
    var systemStyle: MenuSystemStyle = .off
    var cpuUsage: Double?
    var gpuUsage: Double?
    /// Buchstabe + Wert je Zeile (max. 2); leer = kein Block.
    var thermalRows: [(letter: String, value: String)] = []
    /// Verlauf 0…1 (links alt, rechts neu); nil = keine Sparkline.
    var sparkline: [Double]?
}

/// Das Live-Label in der Menüleiste — zeigt den Datenspeed der gewählten Gruppe
/// und optional Sparkline, CPU-/GPU-Auslastung sowie Temperatur/Lüfter.
///
/// Alle Stile werden als NSImage gerendert: MenuBarExtra stellt mehrzeilige
/// SwiftUI-Layouts nicht dar und erzwingt Template-Rendering (keine Farben).
struct MenuBarLabel: View {
    let engine: StatsEngine

    var body: some View {
        Image(nsImage: LabelImageRenderer.render(engine.menuLabelSpec()))
    }
}

extension StatsEngine {
    /// Unterhalb dieser Summe gilt die Gruppe als „ruhig" (Werte ausblenden).
    static let idleThreshold: Double = 100_000
    static let sparklineWindow: TimeInterval = 30

    /// Baut aus Messwerten und Einstellungen die Vorlage fürs Menüleisten-Bild.
    func menuLabelSpec() -> MenuLabelSpec {
        let group = selectedGroup
        let state = state(for: group)
        let idle = menuHideIdle && state.read + state.write < Self.idleThreshold

        var style = labelStyle
        if idle { style = .symbolOnly }
        if menuChannel != .both, style == .split { style = .single }

        let single: String
        switch menuChannel {
        case .both: single = SpeedFormat.speed(state.read + state.write, units: units)
        case .read: single = "\(group.readGlyph) \(SpeedFormat.speed(state.read, units: units))"
        case .write: single = "\(group.writeGlyph) \(SpeedFormat.speed(state.write, units: units))"
        }

        var spec = MenuLabelSpec(
            group: group,
            labelStyle: style,
            iconStyle: iconStyle,
            tintText: menuTintText,
            singleLine: single,
            readLine: "\(group.readGlyph) \(SpeedFormat.speed(state.read, units: units, compact: true))",
            writeLine: "\(group.writeGlyph) \(SpeedFormat.speed(state.write, units: units, compact: true))",
            systemStyle: menuSystemStyle,
            cpuUsage: system.cpuUsage,
            gpuUsage: system.gpuUsage
        )
        spec.thermalRows = thermalRows()
        if menuSparkline, !idle {
            spec.sparkline = sparklineValues(for: group)
        }
        return spec
    }

    private func thermalRows() -> [(letter: String, value: String)] {
        func temp(_ t: Double?) -> String { t.map { "\(Int($0.rounded()))°" } ?? "–" }
        func rpm() -> String {
            system.fans.map(\.rpm).max().map { "\(Int($0.rounded()))" } ?? "–"
        }
        switch menuThermal {
        case .off:
            return []
        case .temp:
            return [("C", temp(system.cpuTemp)), ("G", temp(system.gpuTemp))]
        case .fan:
            return [("F", rpm())]
        case .both:
            let hottest = [system.cpuTemp, system.gpuTemp].compactMap { $0 }.max()
            return [("T", temp(hottest)), ("F", rpm())]
        }
    }

    /// Summe Lesen+Schreiben der letzten 30 s, normalisiert auf das
    /// Fenster-Maximum (mindestens 1 MB/s, damit Leerlauf flach bleibt).
    private func sparklineValues(for group: SpeedGroup) -> [Double] {
        let cutoff = lastSampleDate.addingTimeInterval(-Self.sparklineWindow)
        let values = state(for: group).samples
            .filter { $0.date >= cutoff }
            .map { $0.read + $0.write }
        guard !values.isEmpty else { return [] }
        let peak = max(values.max() ?? 0, 1_000_000)
        return values.map { $0 / peak }
    }
}

@MainActor
enum LabelImageRenderer {
    /// Zeichnet Symbol, optionale Sparkline, Text und Info-Blöcke in ein
    /// Menüleisten-Bild. Outline/Gefüllt entstehen als Template-Bild (System
    /// färbt hell/dunkel), Farbig als normales Bild mit Gruppenfarbe.
    static func render(_ spec: MenuLabelSpec) -> NSImage {
        let isColor = spec.iconStyle == .color
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let tint = NSColor(spec.group.tint)
        let textColor: NSColor = isColor ? (spec.tintText ? tint : (isDark ? .white : .black)) : .black
        let symbolColor: NSColor = isColor ? tint : .black

        let symbolName = spec.group.symbol(for: spec.iconStyle)
        let symbolSize: CGFloat = spec.labelStyle == .single ? 13 : 11.5
        var symbolConfig = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
        if isColor {
            symbolConfig = symbolConfig.applying(.init(paletteColors: [symbolColor]))
        }
        let symbol = (NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
                      ?? NSImage(systemSymbolName: spec.group.symbol, accessibilityDescription: nil))?
            .withSymbolConfiguration(symbolConfig)
        let symbolWidth = ceil(symbol?.size.width ?? 0)

        let height: CGFloat = 22
        let gap: CGFloat = 4
        let blockGap: CGFloat = 7

        // Textzeilen je nach Stil vorbereiten
        let lines: [NSAttributedString]
        switch spec.labelStyle {
        case .symbolOnly:
            lines = []
        case .single:
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            lines = [NSAttributedString(string: spec.singleLine,
                                        attributes: [.font: font, .foregroundColor: textColor])]
        case .split:
            let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            lines = [NSAttributedString(string: spec.readLine, attributes: attrs),
                     NSAttributedString(string: spec.writeLine, attributes: attrs)]
        }

        // Mindestbreite, damit das Label bei wechselnden Ziffern kaum springt
        let rawTextWidth = lines.map { ceil($0.size().width) }.max() ?? 0
        let textWidth = lines.isEmpty ? 0 : max(rawTextWidth, spec.labelStyle == .split ? 38 : 52)

        let sparkWidth: CGFloat = spec.sparkline == nil ? 0 : 34
        let sparkHeight: CGFloat = 14

        let systemBlock: InfoBlock? = spec.systemStyle == .off ? nil : InfoBlock(
            rows: [.init(letter: "C", text: InfoBlock.percent(spec.cpuUsage), fraction: spec.cpuUsage),
                   .init(letter: "G", text: InfoBlock.percent(spec.gpuUsage), fraction: spec.gpuUsage)],
            bar: spec.systemStyle == .bar,
            textColor: textColor
        )
        let thermalBlock: InfoBlock? = spec.thermalRows.isEmpty ? nil : InfoBlock(
            rows: spec.thermalRows.prefix(2).map { .init(letter: $0.letter, text: $0.value, fraction: nil) },
            bar: false,
            textColor: textColor
        )

        var width = symbolWidth
        if sparkWidth > 0 { width += gap + sparkWidth }
        if !lines.isEmpty { width += gap + textWidth }
        if let systemBlock { width += blockGap + systemBlock.width }
        if let thermalBlock { width += blockGap + thermalBlock.width }

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        var x: CGFloat = 0

        if let symbol {
            let symSize = symbol.size
            symbol.draw(in: NSRect(x: x, y: (height - symSize.height) / 2,
                                   width: symSize.width, height: symSize.height),
                        from: .zero, operation: .sourceOver,
                        fraction: isColor ? 1.0 : 0.85)
            x += symbolWidth
        }

        if let values = spec.sparkline {
            x += gap
            drawSparkline(values,
                          in: NSRect(x: x, y: (height - sparkHeight) / 2, width: sparkWidth, height: sparkHeight),
                          color: isColor ? tint : .black)
            x += sparkWidth
        }

        if !lines.isEmpty {
            x += gap
            let right = x + textWidth
            switch lines.count {
            case 1:
                let size = lines[0].size()
                lines[0].draw(at: NSPoint(x: right - size.width, y: (height - size.height) / 2))
            default:
                let lineHeight = height / 2
                let readSize = lines[0].size()
                let writeSize = lines[1].size()
                lines[0].draw(at: NSPoint(x: right - readSize.width,
                                          y: lineHeight + (lineHeight - readSize.height) / 2 + 0.5))
                lines[1].draw(at: NSPoint(x: right - writeSize.width,
                                          y: (lineHeight - writeSize.height) / 2 + 0.5))
            }
            x = right
        }

        if let systemBlock {
            x += blockGap
            systemBlock.draw(atX: x, height: height)
            x += systemBlock.width
        }
        if let thermalBlock {
            x += blockGap
            thermalBlock.draw(atX: x, height: height)
        }

        image.unlockFocus()
        image.isTemplate = !isColor
        return image
    }

    /// Kleine Fläche + Linie; bei zu wenig Daten eine flache Grundlinie.
    private static func drawSparkline(_ values: [Double], in rect: NSRect, color: NSColor) {
        let baseline = rect.minY + 1
        guard values.count >= 2 else {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: rect.minX, y: baseline))
            line.line(to: NSPoint(x: rect.maxX, y: baseline))
            color.withAlphaComponent(0.4).setStroke()
            line.lineWidth = 1
            line.stroke()
            return
        }
        let step = rect.width / CGFloat(values.count - 1)
        let usable = rect.height - 2
        func point(_ i: Int) -> NSPoint {
            NSPoint(x: rect.minX + CGFloat(i) * step,
                    y: baseline + usable * CGFloat(min(max(values[i], 0), 1)))
        }
        let line = NSBezierPath()
        line.move(to: point(0))
        for i in 1..<values.count { line.line(to: point(i)) }

        let area = NSBezierPath()
        area.append(line)
        area.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        area.line(to: NSPoint(x: rect.minX, y: rect.minY))
        area.close()
        color.withAlphaComponent(0.22).setFill()
        area.fill()

        color.setStroke()
        line.lineWidth = 1
        line.lineJoinStyle = .round
        line.stroke()
    }
}

// MARK: - Info-Block (CPU/GPU bzw. Temperatur/Lüfter)

/// Ein- oder zweizeiliger Block „Buchstabe + Wert" — als Text oder als
/// kleiner Fortschrittsbalken (`fraction`).
@MainActor
private struct InfoBlock {
    struct Row {
        let letter: String
        let text: String
        let fraction: Double?
    }

    let rows: [Row]
    let bar: Bool
    let textColor: NSColor

    private static let letterFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private static let barWidth: CGFloat = 26
    private static let barHeight: CGFloat = 5
    /// Feste Wertspalte gegen Zittern bei wechselnden Ziffern ("100%", "2300")
    private static let valueWidth: CGFloat = 24

    static func percent(_ v: Double?) -> String {
        v.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
    }

    private var letterWidth: CGFloat {
        ceil(NSAttributedString(string: "G", attributes: [.font: Self.letterFont]).size().width)
    }

    var width: CGFloat {
        letterWidth + 3 + (bar ? Self.barWidth : Self.valueWidth)
    }

    func draw(atX x: CGFloat, height: CGFloat) {
        let lineHeight = height / 2
        if rows.count == 1 {
            drawRow(rows[0], x: x, midY: height / 2 + 0.5)
        } else {
            for (i, row) in rows.prefix(2).enumerated() {
                let midY = i == 0 ? lineHeight + lineHeight / 2 + 0.5 : lineHeight / 2 + 0.5
                drawRow(row, x: x, midY: midY)
            }
        }
    }

    private func drawRow(_ row: Row, x: CGFloat, midY: CGFloat) {
        let letterAttr = NSAttributedString(string: row.letter,
                                            attributes: [.font: Self.letterFont,
                                                         .foregroundColor: textColor])
        let letterSize = letterAttr.size()
        letterAttr.draw(at: NSPoint(x: x, y: midY - letterSize.height / 2))

        let contentX = x + letterWidth + 3
        if bar {
            let barRect = NSRect(x: contentX, y: midY - Self.barHeight / 2,
                                 width: Self.barWidth, height: Self.barHeight)
            let radius = Self.barHeight / 2
            let outline = NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius)
            textColor.withAlphaComponent(0.35).setStroke()
            outline.lineWidth = 1
            outline.stroke()
            if let value = row.fraction, value > 0 {
                let fillWidth = max(Self.barHeight, barRect.width * min(max(value, 0), 1))
                let fillRect = NSRect(x: barRect.minX, y: barRect.minY,
                                      width: fillWidth, height: barRect.height)
                let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
                textColor.setFill()
                fill.fill()
            }
        } else {
            let attr = NSAttributedString(string: row.text,
                                          attributes: [.font: Self.valueFont,
                                                       .foregroundColor: textColor])
            let size = attr.size()
            // rechtsbündig innerhalb der festen Wertspalte
            attr.draw(at: NSPoint(x: contentX + Self.valueWidth - size.width, y: midY - size.height / 2))
        }
    }
}
