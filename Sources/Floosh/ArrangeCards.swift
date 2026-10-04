import SwiftUI
import AppKit

// MARK: - Kacheln anordnen

/// Ziehen einer Kachel innerhalb von floosh. Transportiert wird ein Text mit
/// Präfix — so bleibt es ohne eigenen Datentyp in der Info.plist, und aus dem
/// Finder gezogene Dateien (URLs) werden nie für eine Kachel gehalten.
enum CardDrag {
    private static let prefix = "floosh-card:"

    static func token(for card: DashboardCard) -> String {
        prefix + card.rawValue
    }

    static func card(from token: String) -> DashboardCard? {
        guard token.hasPrefix(prefix) else { return nil }
        return DashboardCard(rawValue: String(token.dropFirst(prefix.count)))
    }
}

/// Kachel im Anordnen-Modus: Inhalt gesperrt und leicht gedämpft, darüber
/// Griff und Auge zum Ausblenden; die Einfügemarke zeigt das Ablageziel.
struct ArrangeableCard<Content: View>: View {
    let card: DashboardCard
    let size: CardSize
    let isDropTarget: Bool
    @ViewBuilder let content: Content
    let onHide: () -> Void

    var body: some View {
        // Die echte Kachel bleibt unsichtbar stehen und hält so ihre Größe;
        // gezeigt wird eine ruhige Platzhalter-Kachel. (Abdunkeln oder
        // Überlagern der echten Kachel taugt nicht: Liquid Glass ignoriert
        // die Deckkraft und verschluckt darübergelegten Text.)
        content
            .hidden()
            .allowsHitTesting(false)
            .overlay { placeholder }
            // Einfügemarke links: Die gezogene Kachel landet *vor* dieser
            .overlay(alignment: .leading) {
                if isDropTarget {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 4)
                        .padding(.vertical, 10)
                        .offset(x: -6)
                }
            }
            .contentShape(.rect(cornerRadius: size.cornerRadius))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(card.title), zum Umsortieren ziehen")
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Label(card.title, systemImage: card.symbol)
                .font(.headline)
            Button(action: onHide) {
                Label("Ausblenden", systemImage: "eye.slash")
                    .font(.caption)
            }
            .compatGlassButton()
            .controlSize(.small)
            .help("\(card.title) im Dropdown ausblenden")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardGlass(tint: isDropTarget ? Color.accentColor.opacity(0.18) : nil,
                   cornerRadius: size.cornerRadius)
        .overlay {
            RoundedRectangle(cornerRadius: size.cornerRadius)
                .strokeBorder(Color.accentColor.opacity(isDropTarget ? 0.95 : 0.45),
                              style: StrokeStyle(lineWidth: isDropTarget ? 2.5 : 1.5,
                                                 dash: isDropTarget ? [] : [6, 5]))
        }
    }
}

/// Kleines Vorschaubild beim Ziehen — statt der ganzen, schweren Kachel.
struct ArrangeDragPreview: View {
    let card: DashboardCard

    var body: some View {
        Label(card.title, systemImage: card.symbol)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: .capsule)
    }
}

// MARK: - Fenster verschieben

/// Unsichtbarer Griff: Ziehen bewegt das ganze Fenster (`performDrag`),
/// Doppelklick löst `onDoubleClick` aus. Ohne Fenster (Snapshots) wirkungslos.
struct WindowDragHandle: NSViewRepresentable {
    var onMoved: () -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.onMoved = onMoved
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onMoved = onMoved
        view.onDoubleClick = onDoubleClick
    }

    final class HandleView: NSView {
        var onMoved: (() -> Void)?
        var onDoubleClick: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick?()
                return
            }
            guard let window else { return }
            let before = window.frame.origin
            window.performDrag(with: event) // kehrt erst nach dem Loslassen zurück
            if window.frame.origin != before {
                onMoved?()
            }
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

// MARK: - Eck-Griff für die Spaltenzahl

/// Kleiner Griff in einer unteren Ecke: seitlich ziehen wechselt zwischen
/// 1, 2 und 3 Spalten (rastet ein). Sichtbarer Ersatz für den unsichtbaren
/// Fensterrand.
struct ResizeGrip: View {
    let fromLeft: Bool

    var body: some View {
        // Klassische Diagonalstriche wie unten rechts in macOS-Fenstern;
        // für die linke Ecke gespiegelt
        Canvas { context, size in
            var path = Path()
            for inset in [4.0, 8.5] {
                path.move(to: CGPoint(x: inset, y: size.height - 1))
                path.addLine(to: CGPoint(x: size.width - 1, y: inset))
            }
            context.stroke(path, with: .color(.secondary.opacity(0.75)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .frame(width: 14, height: 14)
        .scaleEffect(x: fromLeft ? -1 : 1)
        .padding(6)
        .background { GripTracker(fromLeft: fromLeft) }
        .help("Seitlich ziehen: 1, 2 oder 3 Spalten")
        .accessibilityLabel("Spaltenzahl ändern")
    }
}

/// Nimmt die Maus für den Griff auf und meldet den Weg an den Controller.
private struct GripTracker: NSViewRepresentable {
    let fromLeft: Bool

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.fromLeft = fromLeft
        return view
    }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.fromLeft = fromLeft
    }

    final class TrackerView: NSView {
        var fromLeft = false
        private var startX: CGFloat = 0

        override func mouseDown(with event: NSEvent) {
            // Bildschirm-Koordinaten: Das Fenster bewegt sich beim Ziehen mit
            startX = NSEvent.mouseLocation.x
            MainActor.assumeIsolated { MenuBarController.shared?.gripBegan() }
        }

        override func mouseDragged(with event: NSEvent) {
            let dx = NSEvent.mouseLocation.x - startX
            let fromLeft = fromLeft
            MainActor.assumeIsolated {
                MenuBarController.shared?.gripDragged(by: dx, fromLeft: fromLeft)
            }
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
    }
}
