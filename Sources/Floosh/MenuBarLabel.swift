import SwiftUI
import AppKit

/// Das Live-Label in der Menüleiste — zeigt den Datenspeed der gewählten Gruppe
/// und optional CPU-/GPU-Auslastung (zweizeilig, als Zahl oder Balken).
///
/// Alle Stile werden als NSImage gerendert: MenuBarExtra stellt mehrzeilige
/// SwiftUI-Layouts nicht dar und erzwingt Template-Rendering (keine Farben).
struct MenuBarLabel: View {
    let engine: StatsEngine

    var body: some View {
        let group = engine.selectedGroup
        let state = engine.state(for: group)

        Image(nsImage: LabelImageRenderer.render(
            group: group,
            labelStyle: engine.labelStyle,
            iconStyle: engine.iconStyle,
            singleLine: SpeedFormat.speed(state.read + state.write, units: engine.units),
            readLine: "\(group.readGlyph) \(SpeedFormat.speed(state.read, units: engine.units, compact: true))",
            writeLine: "\(group.writeGlyph) \(SpeedFormat.speed(state.write, units: engine.units, compact: true))",
            systemStyle: engine.menuSystemStyle,
            cpuUsage: engine.system.cpuUsage,
            gpuUsage: engine.system.gpuUsage
        ))
    }
}

@MainActor
enum LabelImageRenderer {
    /// Zeichnet Symbol + Text in ein Menüleisten-Bild. Outline/Gefüllt entstehen als
    /// Template-Bild (System färbt hell/dunkel), Farbig als normales Bild mit
    /// Gruppenfarbe + appearance-abhängiger Textfarbe.
    static func render(group: SpeedGroup,
                       labelStyle: MenuLabelStyle,
                       iconStyle: MenuIconStyle,
                       singleLine: String,
                       readLine: String,
                       writeLine: String,
                       systemStyle: MenuSystemStyle = .off,
                       cpuUsage: Double? = nil,
                       gpuUsage: Double? = nil) -> NSImage {
        let isColor = iconStyle == .color
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let textColor: NSColor = isColor ? (isDark ? .white : .black) : .black
        let symbolColor: NSColor = isColor ? NSColor(group.tint) : .black

        let symbolName = group.symbol(for: iconStyle)
        let symbolSize: CGFloat = labelStyle == .single ? 13 : 11.5
        var symbolConfig = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
        if isColor {
            symbolConfig = symbolConfig.applying(.init(paletteColors: [symbolColor]))
        }
        let symbol = (NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
                      ?? NSImage(systemSymbolName: group.symbol, accessibilityDescription: nil))?
            .withSymbolConfiguration(symbolConfig)
        let symbolWidth = ceil(symbol?.size.width ?? 0)

        let height: CGFloat = 22
        let gap: CGFloat = 4

        // Textzeilen je nach Stil vorbereiten
        let lines: [NSAttributedString]
        switch labelStyle {
        case .symbolOnly:
            lines = []
        case .single:
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            lines = [NSAttributedString(string: singleLine,
                                        attributes: [.font: font, .foregroundColor: textColor])]
        case .split:
            let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            lines = [NSAttributedString(string: readLine, attributes: attrs),
                     NSAttributedString(string: writeLine, attributes: attrs)]
        }

        // Mindestbreite, damit das Label bei wechselnden Ziffern kaum springt
        let rawTextWidth = lines.map { ceil($0.size().width) }.max() ?? 0
        let textWidth = lines.isEmpty ? 0 : max(rawTextWidth, labelStyle == .split ? 38 : 52)
        let speedWidth = symbolWidth + (lines.isEmpty ? 0 : gap + textWidth)

        // CPU/GPU-Block (zweizeilig): "C 42%" / "G 7%" oder Buchstabe + Balken
        let systemBlockGap: CGFloat = systemStyle == .off ? 0 : 7
        let systemBlock = systemStyle == .off ? nil : SystemBlock(
            style: systemStyle,
            cpu: cpuUsage, gpu: gpuUsage,
            textColor: textColor
        )
        let width = speedWidth + (systemBlock.map { systemBlockGap + $0.width } ?? 0)

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        if let symbol {
            let symSize = symbol.size
            symbol.draw(in: NSRect(x: 0, y: (height - symSize.height) / 2,
                                   width: symSize.width, height: symSize.height),
                        from: .zero, operation: .sourceOver,
                        fraction: isColor ? 1.0 : 0.85)
        }
        switch lines.count {
        case 1:
            let size = lines[0].size()
            lines[0].draw(at: NSPoint(x: speedWidth - size.width, y: (height - size.height) / 2))
        case 2:
            let lineHeight = height / 2
            let readSize = lines[0].size()
            let writeSize = lines[1].size()
            lines[0].draw(at: NSPoint(x: speedWidth - readSize.width,
                                      y: lineHeight + (lineHeight - readSize.height) / 2 + 0.5))
            lines[1].draw(at: NSPoint(x: speedWidth - writeSize.width,
                                      y: (lineHeight - writeSize.height) / 2 + 0.5))
        default:
            break
        }
        systemBlock?.draw(atX: speedWidth + systemBlockGap, height: height)
        image.unlockFocus()
        image.isTemplate = !isColor
        return image
    }
}

// MARK: - CPU/GPU-Block

/// Zweizeiliger Auslastungs-Block: oben CPU, unten GPU — als Prozentzahl
/// oder als kleiner Fortschrittsbalken.
@MainActor
private struct SystemBlock {
    let style: MenuSystemStyle
    let cpu: Double?
    let gpu: Double?
    let textColor: NSColor

    private static let letterFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private static let barWidth: CGFloat = 26
    private static let barHeight: CGFloat = 5

    private func valueString(_ v: Double?) -> String {
        v.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
    }

    private var letterWidth: CGFloat {
        ceil(NSAttributedString(string: "G", attributes: [.font: Self.letterFont]).size().width)
    }

    var width: CGFloat {
        switch style {
        case .off: 0
        case .number:
            // Buchstabe + Wert; Mindestbreite gegen Zittern bei wechselnden Ziffern
            letterWidth + 3 + 24
        case .bar:
            letterWidth + 3 + Self.barWidth
        }
    }

    func draw(atX x: CGFloat, height: CGFloat) {
        let lineHeight = height / 2
        drawLine(letter: "C", value: cpu, x: x,
                 midY: lineHeight + lineHeight / 2 + 0.5, lineHeight: lineHeight)
        drawLine(letter: "G", value: gpu, x: x,
                 midY: lineHeight / 2 + 0.5, lineHeight: lineHeight)
    }

    private func drawLine(letter: String, value: Double?, x: CGFloat, midY: CGFloat, lineHeight: CGFloat) {
        let letterAttr = NSAttributedString(string: letter,
                                            attributes: [.font: Self.letterFont,
                                                         .foregroundColor: textColor])
        let letterSize = letterAttr.size()
        letterAttr.draw(at: NSPoint(x: x, y: midY - letterSize.height / 2))

        let contentX = x + letterWidth + 3
        switch style {
        case .off:
            break
        case .number:
            let attr = NSAttributedString(string: valueString(value),
                                          attributes: [.font: Self.valueFont,
                                                       .foregroundColor: textColor])
            let size = attr.size()
            // rechtsbündig innerhalb der festen Wertspalte
            attr.draw(at: NSPoint(x: contentX + 24 - size.width, y: midY - size.height / 2))
        case .bar:
            let barRect = NSRect(x: contentX, y: midY - Self.barHeight / 2,
                                 width: Self.barWidth, height: Self.barHeight)
            let radius = Self.barHeight / 2
            let outline = NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius)
            textColor.withAlphaComponent(0.35).setStroke()
            outline.lineWidth = 1
            outline.stroke()
            if let value, value > 0 {
                let fillWidth = max(Self.barHeight, barRect.width * min(max(value, 0), 1))
                let fillRect = NSRect(x: barRect.minX, y: barRect.minY,
                                      width: fillWidth, height: barRect.height)
                let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
                textColor.setFill()
                fill.fill()
            }
        }
    }
}
