import SwiftUI

/// Kompatibilitätsschicht für Liquid Glass: ab macOS 26 echtes Glas,
/// auf macOS 14/15 (Intel-Macs, Hackintoshes) eine Material-Optik.
/// Die 26er-Typen (`Glass`, `glassEffect`, `.buttonStyle(.glass)`) dürfen
/// bei Deployment-Target 14 nur hinter `#available` auftauchen.
extension View {

    /// Karten-Hintergrund: Liquid Glass bzw. Material-Fallback; im
    /// Snapshot-Modus eine einfache Fläche, weil `ImageRenderer`
    /// glassEffect-Inhalte nicht darstellt.
    @ViewBuilder
    func cardGlass(tint: Color? = nil, interactive: Bool = false,
                   cornerRadius: CGFloat = 20) -> some View {
        if DebugSnapshot.isActive {
            background(.gray.opacity(0.18), in: .rect(cornerRadius: cornerRadius))
        } else if #available(macOS 26.0, *) {
            glassEffect(Self.glass(tint: tint, interactive: interactive),
                        in: .rect(cornerRadius: cornerRadius))
        } else if let tint {
            background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
                .background(tint, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }

    @available(macOS 26.0, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var g: Glass = .regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }

    /// Glas-Knopf ab macOS 26, sonst der normale umrandete Stil.
    @ViewBuilder
    func compatGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// `GlassEffectContainer` ab macOS 26, davor reicht der Inhalt selbst.
struct CompatGlassContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
