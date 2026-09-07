import SwiftUI

// MARK: - Deckkraft

/// Zusätzliche Füllung hinter jeder Karte, als Umgebungswert durchgereicht.
/// So müssen die einzelnen Karten nichts davon wissen — Dropdown und Panel
/// setzen den Wert einmal am Wurzel-View.
private struct CardInkKey: EnvironmentKey {
    static let defaultValue: Double = 0
}

extension EnvironmentValues {
    var cardInkOpacity: Double {
        get { self[CardInkKey.self] }
        set { self[CardInkKey.self] = newValue }
    }
}

/// „Tinte" für Flächen hinter dem Glas: im Dunkelmodus schwarz, im Hellmodus
/// weiß — beides erhöht den Kontrast zum Text, statt ihn zu schlucken.
private func inkColor(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? .black : .white
}

/// Legt die Füllung zwischen Glas und Karteninhalt: Das Glas bleibt darunter,
/// der Text darüber — der Text wird also nicht blass, nur der Untergrund dichter.
private struct CardInk: ViewModifier {
    @Environment(\.cardInkOpacity) private var ink
    @Environment(\.colorScheme) private var scheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if ink <= 0.001 || DebugSnapshot.isActive {
            content
        } else {
            content.background(inkColor(scheme).opacity(ink * 0.7),
                               in: .rect(cornerRadius: cornerRadius))
        }
    }
}

/// Trägerfläche hinter *allen* Karten. Ohne sie scheint zwischen den Karten
/// der Schreibtisch durch — das war bis 1.6 das ganze Erscheinungsbild.
private struct Backdrop: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let opacity: Double
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if opacity <= 0.001 || DebugSnapshot.isActive {
            content
        } else {
            content.background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)
                    .opacity(opacity)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(inkColor(scheme).opacity(opacity * 0.55))
                    }
            }
        }
    }
}

// MARK: - Liquid Glass

/// Kompatibilitätsschicht für Liquid Glass: ab macOS 26 echtes Glas,
/// auf macOS 14/15 (Intel-Macs, Hackintoshes) eine Material-Optik.
/// Die 26er-Typen (`Glass`, `glassEffect`, `.buttonStyle(.glass)`) dürfen
/// bei Deployment-Target 14 nur hinter `#available` auftauchen.
extension View {

    /// Karten-Hintergrund: Liquid Glass bzw. Material-Fallback; im
    /// Snapshot-Modus eine einfache Fläche, weil `ImageRenderer`
    /// glassEffect-Inhalte nicht darstellt.
    func cardGlass(tint: Color? = nil, interactive: Bool = false,
                   cornerRadius: CGFloat = 20) -> some View {
        modifier(CardInk(cornerRadius: cornerRadius))
            .glassLayer(tint: tint, interactive: interactive, cornerRadius: cornerRadius)
    }

    /// Die Trägerfläche des ganzen Fensters (Dropdown, Desktop-Panel).
    func dashboardBackdrop(opacity: Double, cornerRadius: CGFloat) -> some View {
        modifier(Backdrop(opacity: opacity, cornerRadius: cornerRadius))
    }

    @ViewBuilder
    private func glassLayer(tint: Color?, interactive: Bool,
                            cornerRadius: CGFloat) -> some View {
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
