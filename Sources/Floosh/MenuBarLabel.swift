import SwiftUI
import AppKit

/// Das Live-Label in der Menüleiste — zeigt den Datenspeed der gewählten Gruppe.
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
            writeLine: "\(group.writeGlyph) \(SpeedFormat.speed(state.write, units: engine.units, compact: true))"
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
                       writeLine: String) -> NSImage {
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
        let width = symbolWidth + (lines.isEmpty ? 0 : gap + textWidth)

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
            lines[0].draw(at: NSPoint(x: width - size.width, y: (height - size.height) / 2))
        case 2:
            let lineHeight = height / 2
            let readSize = lines[0].size()
            let writeSize = lines[1].size()
            lines[0].draw(at: NSPoint(x: width - readSize.width,
                                      y: lineHeight + (lineHeight - readSize.height) / 2 + 0.5))
            lines[1].draw(at: NSPoint(x: width - writeSize.width,
                                      y: (lineHeight - writeSize.height) / 2 + 0.5))
        default:
            break
        }
        image.unlockFocus()
        image.isTemplate = !isColor
        return image
    }
}
