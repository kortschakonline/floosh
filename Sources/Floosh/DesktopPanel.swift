import SwiftUI
import AppKit
import Observation

// MARK: - Einstellungen

/// Einstellungen des Desktop-Panels: ein rahmenloses Fenster mit den Karten,
/// wahlweise auf Desktop-Ebene (hinter allen Fenstern, wie ein Widget) oder
/// schwebend über allen Fenstern.
@MainActor
@Observable
final class PanelSettings {

    static let shared = PanelSettings()

    enum Level: String, CaseIterable, Identifiable {
        case desktop, floating
        var id: String { rawValue }
        var title: String { self == .desktop ? "Desktop" : "Schwebend" }
        var detail: String {
            self == .desktop
                ? "Hinter allen Fenstern, direkt auf dem Schreibtisch — wie ein Widget."
                : "Über allen Fenstern, immer sichtbar."
        }
    }

    enum Position: String, CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight
        var id: String { rawValue }
        var title: String {
            switch self {
            case .topLeft: "Oben links"
            case .topRight: "Oben rechts"
            case .bottomLeft: "Unten links"
            case .bottomRight: "Unten rechts"
            }
        }
    }

    /// Die Karten sind dieselben wie im Dropdown.
    typealias Card = DashboardCard

    var enabled: Bool { didSet { defaults.set(enabled, forKey: "panel.enabled") } }
    var level: Level { didSet { defaults.set(level.rawValue, forKey: "panel.level") } }
    var position: Position { didSet { defaults.set(position.rawValue, forKey: "panel.position") } }
    /// Abstand vom Bildschirmrand in Punkten.
    var margin: Double { didSet { defaults.set(margin, forKey: "panel.margin") } }
    /// Deckkraft 0,3…1.
    var opacity: Double { didSet { defaults.set(opacity, forKey: "panel.opacity") } }
    var layout: DropdownLayout { didSet { defaults.set(layout.rawValue, forKey: "panel.layout") } }
    var cards: Set<Card> { didSet { defaults.set(cards.map(\.rawValue), forKey: "panel.cards") } }
    var allSpaces: Bool { didSet { defaults.set(allSpaces, forKey: "panel.allSpaces") } }
    /// `localizedName` des Ziel-Bildschirms; leer = Hauptbildschirm (mit Menüleiste).
    var screenName: String { didSet { defaults.set(screenName, forKey: "panel.screen") } }

    private let defaults = UserDefaults.standard

    init() {
        enabled = defaults.object(forKey: "panel.enabled") as? Bool ?? false
        level = Level(rawValue: defaults.string(forKey: "panel.level") ?? "") ?? .desktop
        position = Position(rawValue: defaults.string(forKey: "panel.position") ?? "") ?? .topRight
        margin = defaults.object(forKey: "panel.margin") as? Double ?? 24
        opacity = defaults.object(forKey: "panel.opacity") as? Double ?? 1
        layout = DropdownLayout(rawValue: defaults.string(forKey: "panel.layout") ?? "") ?? .list
        let saved = defaults.stringArray(forKey: "panel.cards")?.compactMap(Card.init(rawValue:))
        cards = saved.map(Set.init) ?? Set(Card.allCases.filter { $0 != .shelf && $0 != .shortcuts })
        allSpaces = defaults.object(forKey: "panel.allSpaces") as? Bool ?? true
        screenName = defaults.string(forKey: "panel.screen") ?? ""
    }

    /// Sichtbare Karten in der Reihenfolge, die im Motor eingestellt ist —
    /// Dropdown und Panel sortieren gleich.
    var orderedCards: [Card] { StatsEngine.shared.ordered(cards) }

    func binding(for card: Card) -> Binding<Bool> {
        Binding { [self] in
            cards.contains(card)
        } set: { [self] on in
            if on { cards.insert(card) } else { cards.remove(card) }
        }
    }
}

// MARK: - Inhalt

/// Die Karten des Panels — ohne Kopf- und Fußzeile, Größe folgt der
/// Kachelgröße des Dropdowns.
struct DesktopPanelView: View {
    let engine: StatsEngine
    var fans: FanService = .shared
    var settings: PanelSettings = .shared

    var body: some View {
        let size = engine.cardSize
        let cards = settings.orderedCards
        let grid = settings.layout == .grid
        CompatGlassContainer(spacing: size.outerSpacing) {
            VStack(spacing: size.outerSpacing) {
                if cards.isEmpty {
                    Text("Keine Karten ausgewählt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(size.padding)
                        .frame(maxWidth: .infinity)
                        .cardGlass(cornerRadius: size.cornerRadius)
                } else {
                    let rows = DashboardCard.rows(cards, layout: settings.layout)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        if row.count == 1 {
                            card(row[0])
                        } else {
                            HStack(alignment: .top, spacing: size.outerSpacing) {
                                ForEach(row) { card($0, compact: settings.layout == .split) }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            // Etwas Luft, damit Glas-Ränder und Hover-Highlights nicht am
            // Fensterrand beschnitten werden
            .padding(4)
        }
        .frame(width: (grid ? size.gridWidth - 2 * size.outerPadding : size.dropdownWidth - 2 * size.outerPadding) + 8)
        .dashboardBackdrop(opacity: engine.backdropOpacity,
                           cornerRadius: size.cornerRadius + 6)
        .environment(\.cardInkOpacity, engine.cardOpacity)
    }

    private func card(_ card: DashboardCard, compact: Bool = false) -> some View {
        DashboardCardView(card: card, engine: engine, fans: fans, compact: compact)
    }
}

// MARK: - Fenster

/// Hält das Panel-Fenster und spiegelt die Einstellungen (Ebene, Position,
/// Deckkraft, Sichtbarkeit) darauf; die Inhaltsgröße folgt SwiftUI.
@MainActor
final class DesktopPanelController {

    static let shared = DesktopPanelController()

    private let settings = PanelSettings.shared
    private var engine: StatsEngine?
    private var window: NSPanel?
    private var observers: [Any] = []

    func attach(engine: StatsEngine) {
        self.engine = engine
        observeSettings()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        })
    }

    /// Alle Bildschirme für die Auswahl in den Einstellungen.
    static var screenNames: [String] {
        NSScreen.screens.map(\.localizedName)
    }

    // MARK: Beobachtung

    private func observeSettings() {
        withObservationTracking { [self] in
            _ = settings.enabled
            _ = settings.level
            _ = settings.position
            _ = settings.margin
            _ = settings.opacity
            _ = settings.allSpaces
            _ = settings.screenName
            apply()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSettings() }
        }
    }

    private func apply() {
        guard settings.enabled, let engine else {
            window?.orderOut(nil)
            return
        }
        let panel = window ?? makeWindow(engine: engine)
        panel.level = settings.level == .desktop
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
            : .floating
        panel.hasShadow = settings.level == .floating
        panel.alphaValue = settings.opacity
        var behavior: NSWindow.CollectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        if settings.allSpaces { behavior.insert(.canJoinAllSpaces) } else { behavior.insert(.moveToActiveSpace) }
        panel.collectionBehavior = behavior
        reposition()
        panel.orderFrontRegardless()
    }

    private func makeWindow(engine: StatsEngine) -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.titleVisibility = .hidden

        let host = NSHostingController(rootView: DesktopPanelView(engine: engine))
        // Fenstergröße folgt der Idealgröße des SwiftUI-Inhalts (Geräteliste
        // wächst/schrumpft) — danach wieder an der gewählten Ecke ausrichten
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.setContentSize(host.view.fittingSize)

        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        })
        window = panel
        return panel
    }

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if !settings.screenName.isEmpty,
           let match = screens.first(where: { $0.localizedName == settings.screenName }) {
            return match
        }
        return screens.first
    }

    private func reposition() {
        guard let window, let screen = targetScreen() else { return }
        let area = screen.visibleFrame
        let size = window.frame.size
        let m = CGFloat(settings.margin)
        let origin: CGPoint
        switch settings.position {
        case .topLeft: origin = CGPoint(x: area.minX + m, y: area.maxY - m - size.height)
        case .topRight: origin = CGPoint(x: area.maxX - m - size.width, y: area.maxY - m - size.height)
        case .bottomLeft: origin = CGPoint(x: area.minX + m, y: area.minY + m)
        case .bottomRight: origin = CGPoint(x: area.maxX - m - size.width, y: area.minY + m)
        }
        if window.frame.origin != origin {
            window.setFrameOrigin(origin)
        }
    }
}
