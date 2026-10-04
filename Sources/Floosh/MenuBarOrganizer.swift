import SwiftUI
import AppKit
import Observation

/// Menüleisten-Organizer, Stufe 1: fremde Symbole verstecken — ohne Sonderrechte.
///
/// Prinzip (wie Hidden Bar/Ice): drei eigene `NSStatusItem`s, von rechts nach links
///
///     [immer versteckt …] ┆ [versteckt …] │ ‹ [sichtbar …]
///
/// - `toggle` (‹ / ›) bleibt immer sichtbar und klappt aus/ein.
/// - `hiddenDivider` (│): Im eingeklappten Zustand wird er „unendlich" breit
///   (Länge 10 000) und schiebt alles links von sich aus dem Bild.
/// - `alwaysDivider` (┆): dasselbe für den Bereich „immer versteckt", der nur
///   per ⌥-Klick aufgeht.
///
/// Welche Symbole wohin gehören, legt man mit macOS-Bordmitteln fest:
/// ⌘ gedrückt halten und Symbole ziehen. Die Positionen merkt sich macOS über
/// `autosaveName`.
@MainActor
@Observable
final class MenuBarOrganizer {
    static let shared = MenuBarOrganizer()

    // MARK: Einstellungen

    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "organizer.enabled")
            enabled ? start() : stop()
        }
    }
    /// Sekunden bis zum automatischen Einklappen; 0 = nie.
    var autoHideDelay: Double {
        didSet { defaults.set(autoHideDelay, forKey: "organizer.autoHide") }
    }
    /// Ausklappen, sobald der Zeiger über dem Pfeil steht.
    var hoverReveal: Bool {
        didSet { defaults.set(hoverReveal, forKey: "organizer.hover") }
    }
    /// Stufe 2: Versteckte Symbole in einer eigenen Leiste unter der Menüleiste
    /// zeigen, statt die Menüleiste auszuklappen (braucht Bedienungshilfen +
    /// Bildschirmaufnahme).
    var barMode: Bool {
        didSet {
            defaults.set(barMode, forKey: "organizer.barMode")
            if barMode {
                MenuBarItems.shared.requestPermissions()
            } else {
                HiddenItemsBar.shared.close()
            }
        }
    }

    var isRunning: Bool { toggle != nil }

    // MARK: Zustand

    private(set) var isExpanded = false
    private(set) var showsAlwaysHidden = false

    private let defaults = UserDefaults.standard
    private var toggle: NSStatusItem?
    private var hiddenDivider: NSStatusItem?
    private var alwaysDivider: NSStatusItem?
    private var collapseTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var monitors: [Any] = []
    private var appSwitchObserver: NSObjectProtocol?
    private var refitTask: Task<Void, Never>?

    /// Namen der Trenner für die Bedienungshilfen — darüber findet Stufe 2
    /// ihre Lage im selben Koordinatensystem wie alle anderen Symbole.
    static let hiddenDividerLabel = "floosh-Trenner versteckt"
    static let alwaysDividerLabel = "floosh-Trenner immer versteckt"

    /// So breit wird ein Trenner, um alles links von ihm hinauszuschieben.
    private static let hidingLength: CGFloat = 10_000

    private init() {
        enabled = defaults.object(forKey: "organizer.enabled") as? Bool ?? false
        autoHideDelay = defaults.object(forKey: "organizer.autoHide") as? Double ?? 10
        hoverReveal = defaults.object(forKey: "organizer.hover") as? Bool ?? true
        barMode = defaults.object(forKey: "organizer.barMode") as? Bool ?? false
    }

    /// Ohne Notch muss floosh wissen, wo die App-Menüs enden — das geht nur
    /// über die Bedienungshilfen. Fehlt das Recht, bleiben die Symbole sichtbar.
    var needsAccessibility: Bool {
        guard !AXIsProcessTrusted() else { return false }
        let screen = toggle?.button?.window?.screen ?? NSScreen.main
        return !(screen.map(Self.hasNotch) ?? false)
    }

    private static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.auxiliaryTopRightArea != nil && screen.safeAreaInsets.top > 0
    }

    /// Leiste statt Ausklappen — nur, wenn die Rechte auch wirklich da sind.
    private var usesBar: Bool {
        barMode && MenuBarItems.shared.hasAllPermissions
    }

    // MARK: Start/Stopp

    func start() {
        guard enabled, toggle == nil else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        OrganizerLog.write("Start floosh \(version), Bedienungshilfen \(AXIsProcessTrusted() ? "ja" : "nein"), Leiste \(barMode ? "ja" : "nein")")
        if Self.seedPositionsIfNeeded() {
            // floosh selbst soll rechts vom Pfeil sichtbar bleiben
            MenuBarController.shared?.recreateStatusItem()
        }
        // Reihenfolge zählt: Neue Symbole setzt macOS links neben die
        // vorhandenen — so entsteht beim ersten Start [┆][│][‹].
        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        toggle.autosaveName = "digital.jrn.floosh.organizer.toggle"
        toggle.button?.target = self
        toggle.button?.action = #selector(toggleClicked(_:))
        toggle.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.toggle = toggle

        let hidden = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        hidden.autosaveName = "digital.jrn.floosh.organizer.hidden"
        hidden.button?.image = Self.dividerImage(dashed: false)
        hidden.button?.appearsDisabled = true
        hidden.button?.toolTip = "floosh: links von hier = versteckt (⌘-Ziehen zum Anordnen)"
        hidden.button?.setAccessibilityLabel(Self.hiddenDividerLabel)
        self.hiddenDivider = hidden

        let always = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        always.autosaveName = "digital.jrn.floosh.organizer.always"
        always.button?.image = Self.dividerImage(dashed: true)
        always.button?.appearsDisabled = true
        always.button?.toolTip = "floosh: links von hier = immer versteckt (nur per ⌥-Klick)"
        always.button?.setAccessibilityLabel(Self.alwaysDividerLabel)
        self.alwaysDivider = always

        startMonitors()
        startRefitLoop()
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in MenuBarOrganizer.shared.refitAfterAppSwitch() }
        }
        // Erst ausgeklappt anlegen, damit macOS die Trenner platziert — ihre
        // Lage braucht `fillLength` zum Einklappen
        apply(expanded: true, always: true)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            MenuBarOrganizer.shared.collapse()
        }

        // Dev-Hook für Bildprüfungen: nach 3 s alles ausklappen
        if CommandLine.arguments.contains("--organizer-demo") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                MenuBarOrganizer.shared.expand(includingAlwaysHidden: true)
            }
        }
    }

    func stop() {
        collapseTask?.cancel()
        hoverTask?.cancel()
        trustTask?.cancel()
        trustTask = nil
        refitTask?.cancel()
        refitTask = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let appSwitchObserver { NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver) }
        appSwitchObserver = nil
        for item in [toggle, hiddenDivider, alwaysDivider].compactMap({ $0 }) {
            NSStatusBar.system.removeStatusItem(item)
        }
        toggle = nil
        hiddenDivider = nil
        alwaysDivider = nil
        isExpanded = false
        showsAlwaysHidden = false
    }

    // MARK: Ausklappen/Einklappen

    @objc private func toggleClicked(_ sender: NSStatusBarButton) {
        // Ohne Mausereignis (Bedienungshilfen/VoiceOver „Drücken"): wie Linksklick
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseUp || event.type == .rightMouseUp else {
            if usesBar {
                HiddenItemsBar.shared.toggle(includingAlwaysHidden: false)
            } else {
                if isExpanded { collapse() } else { expand() }
            }
            return
        }
        if event.type == .rightMouseUp {
            showMenu()
            return
        }
        if usesBar {
            HiddenItemsBar.shared.toggle(includingAlwaysHidden: event.modifierFlags.contains(.option))
            return
        }
        if event.modifierFlags.contains(.option) {
            // ⌥-Klick: alles zeigen, auch „immer versteckt"
            apply(expanded: true, always: !showsAlwaysHidden)
        } else {
            if isExpanded { collapse() } else { expand() }
        }
    }

    /// Für Stufe 2: aus- bzw. einklappen, ohne Automatik und ohne die
    /// Einklapp-Uhr zu starten (MenuBarItems liest dabei die Symbole ein).
    func setExpandedQuietly(_ expanded: Bool, always: Bool) {
        apply(expanded: expanded, always: always, quiet: true)
    }

    /// Wo die Bereiche beginnen (globale x-Koordinaten): links von
    /// `hiddenStart` ist „versteckt", links von `alwaysStart` „immer versteckt".
    /// Nur gültig, solange beide Trenner ausgeklappt sind.
    func sectionBounds() -> (hiddenStart: CGFloat, alwaysStart: CGFloat)? {
        guard isExpanded, showsAlwaysHidden,
              let hidden = frame(of: hiddenDivider), let always = frame(of: alwaysDivider),
              hidden.width < 200, always.width < 200 else { return nil }
        return (hidden.minX, always.minX)
    }

    private func frame(of item: NSStatusItem?) -> NSRect? {
        guard let button = item?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func expand(includingAlwaysHidden: Bool = false) {
        apply(expanded: true, always: includingAlwaysHidden || showsAlwaysHidden)
    }

    func collapse() {
        // Sicherung: Liegt der Pfeil selbst im versteckten Bereich, würde er
        // beim Einklappen mit verschwinden — dann käme man nicht mehr dran
        if toggleIsInsideHiddenSection() {
            warnToggleMisplaced()
            return
        }
        apply(expanded: false, always: false)
        if needsAccessibility { warnMissingAccessibility() }
    }

    private var warnedMisplaced = false
    private var warnedAccessibility = false
    private var trustTask: Task<Void, Never>?

    /// Einmal pro Start erklären, warum ohne Bedienungshilfen nichts
    /// verschwindet, und danach auf die Freigabe warten.
    private func warnMissingAccessibility() {
        watchForTrust()
        guard !warnedAccessibility else { return }
        warnedAccessibility = true
        let alert = NSAlert()
        alert.messageText = "floosh braucht die Bedienungshilfen"
        alert.informativeText = "Auf Bildschirmen ohne Notch muss floosh wissen, wo die Menüs der aktiven App enden — sonst bleiben die versteckten Symbole mitten in der Menüleiste stehen.\n\nNach einem Update verlangt macOS die Freigabe oft neu: In der Liste floosh einmal aus- und wieder einschalten."
        alert.addButton(withTitle: "Freigeben …")
        alert.addButton(withTitle: "Später")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            MenuBarItems.shared.requestPermissions()
            MenuBarItems.shared.openPrivacySettings("Privacy_Accessibility")
        }
    }

    /// Sobald das Recht da ist, die Trennerbreite neu berechnen.
    private func watchForTrust() {
        guard trustTask == nil else { return }
        trustTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.isRunning else { return }
                if AXIsProcessTrusted() {
                    self.trustTask = nil
                    if !self.isExpanded { self.apply(expanded: false, always: false, quiet: true) }
                    return
                }
            }
        }
    }

    /// Lage von Pfeil und Trenner über die Bedienungshilfen (dieselben
    /// Koordinaten wie die Menüleiste). Ohne Recht: keine Prüfung.
    private func toggleIsInsideHiddenSection() -> Bool {
        guard isExpanded, AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success,
              let bar else { return false }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
        var toggleX: CGFloat?
        var dividerX: CGFloat?
        for element in (children as? [AXUIElement]) ?? [] {
            var desc: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &desc)
            var pos: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos)
            var point = CGPoint.zero
            if let pos { AXValueGetValue(pos as! AXValue, .cgPoint, &point) }
            let name = desc as? String ?? ""
            if name == Self.hiddenDividerLabel { dividerX = point.x }
            if name.contains("Symbole verstecken") || name.contains("Versteckte Symbole zeigen") { toggleX = point.x }
        }
        guard let toggleX, let dividerX else { return false }
        return toggleX < dividerX
    }

    private func warnToggleMisplaced() {
        guard !warnedMisplaced else { return }
        warnedMisplaced = true
        let alert = NSAlert()
        alert.messageText = "Der Pfeil liegt im versteckten Bereich"
        alert.informativeText = "Er würde beim Verstecken mit verschwinden. Halte ⌘ gedrückt und ziehe den Pfeil › rechts neben den Trenner │ — dann klappt floosh wieder ein."
        alert.addButton(withTitle: "Verstanden")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func apply(expanded: Bool, always: Bool, quiet: Bool = false, caller: String = #function) {
        // Platz bis zum linken Rand des Symbolbereichs messen, solange die
        // Trenner noch schmal und sichtbar sind
        let hiddenFill = fillLength(for: hiddenDivider)
        let alwaysFill = fillLength(for: alwaysDivider)
        if !expanded {
            OrganizerLog.write("einklappen (\(caller)): Trenner \(OrganizerLog.num(hiddenFill)) / \(OrganizerLog.num(alwaysFill)) · \(Self.lastLimitInfo)")
            logLayoutSoon()
        }
        isExpanded = expanded
        showsAlwaysHidden = expanded && always
        hiddenDivider?.length = expanded ? NSStatusItem.variableLength : (hiddenFill ?? Self.hidingLength)
        alwaysDivider?.length = showsAlwaysHidden ? NSStatusItem.variableLength : (alwaysFill ?? Self.hidingLength)
        // Eingeklappt ist der Trenner eine leere Fläche — ohne Strich darin
        hiddenDivider?.button?.image = expanded ? Self.dividerImage(dashed: false) : nil
        alwaysDivider?.button?.image = showsAlwaysHidden ? Self.dividerImage(dashed: true) : nil
        // Eingeklappt sind beide Trenner „unendlich" breit — der linke liegt
        // dann ohnehin außerhalb, entscheidend ist der rechte (`hiddenDivider`).
        toggle?.button?.image = NSImage(systemSymbolName: expanded ? "chevron.right" : "chevron.left",
                                        accessibilityDescription: expanded ? "Symbole verstecken" : "Versteckte Symbole zeigen")
        toggle?.button?.image?.isTemplate = true
        toggle?.button?.toolTip = expanded
            ? "Klicken: wieder verstecken"
            : "Klicken: versteckte Symbole zeigen · ⌥-Klick: auch „immer versteckt“"
        if quiet {
            collapseTask?.cancel()
        } else {
            scheduleCollapse()
        }
    }

    /// Nach der eingestellten Zeit wieder einklappen — aber nicht, solange der
    /// Zeiger in der Menüleiste steht oder ein Menü offen ist (sonst rutscht
    /// das Symbol unter dem offenen Menü weg).
    private func scheduleCollapse() {
        collapseTask?.cancel()
        guard isExpanded, autoHideDelay > 0 else { return }
        collapseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.autoHideDelay ?? 10))
                guard let self, !Task.isCancelled, self.isExpanded else { return }
                if self.pointerInMenuBar() || Self.menuIsOpen() { continue }
                self.collapse()
                return
            }
        }
    }

    // MARK: Darüberfahren

    private func startMonitors() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { _ in
            Task { @MainActor in MenuBarOrganizer.shared.pointerMoved() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { event in
            Task { @MainActor in MenuBarOrganizer.shared.pointerMoved() }
            return event
        }) { monitors.append(m) }
    }

    private func pointerMoved() {
        guard hoverReveal, !isExpanded, let frame = toggleFrame() else {
            hoverTask?.cancel(); hoverTask = nil
            return
        }
        let inside = frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        if inside, hoverTask == nil {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.hoverTask = nil
                if self.toggleFrame()?.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) == true {
                    if self.usesBar {
                        HiddenItemsBar.shared.show(includingAlwaysHidden: false)
                    } else {
                        self.expand()
                    }
                }
            }
        } else if !inside {
            hoverTask?.cancel()
            hoverTask = nil
        }
    }

    /// Breite, mit der ein Trenner genau bis an den linken Rand des
    /// Symbolbereichs reicht (Notch bzw. Bildschirmrand). macOS 27 blendet
    /// zu breite Symbole einfach aus, statt die anderen wegzuschieben —
    /// passt der Trenner gerade noch hinein, rutscht alles links davon raus.
    private func fillLength(for item: NSStatusItem?) -> CGFloat? {
        guard let item, let button = item.button, let window = button.window else { return nil }
        // Der Pfeil bleibt immer schmal und sichtbar — sein Bildschirm ist
        // verlässlicher als der eines ausgeblendeten, überbreiten Trenners
        guard let screen = toggle?.button?.window?.screen ?? window.screen ?? NSScreen.main else { return nil }
        // Rechte Kante merken, solange der Trenner schmal ist — sie bleibt beim
        // Einklappen stehen und dient später zum Nachrechnen (App-Wechsel).
        // Als Abstand vom rechten Bildschirmrand: Mit mehreren Monitoren
        // wandert der Trenner auf den Bildschirm mit dem Fokus, der Abstand
        // bleibt aber gleich.
        // Bevorzugt über die Bedienungshilfen: Unter macOS 27 stimmt die
        // Fensterlage der Status-Knöpfe nicht mit der Menüleiste überein.
        // Dort zählt die Kante auch eingeklappt, solange macOS den Trenner in
        // der verlangten Breite auslegt (also nicht ausgeblendet hat).
        let label = item === hiddenDivider ? Self.hiddenDividerLabel : Self.alwaysDividerLabel
        if AXIsProcessTrusted(), let ax = Self.axFrame(ofOwnItemLabeled: label), ax.width > 0 {
            if ax.width < 200 || abs(ax.width - item.length) < 2 {
                let axScreen = NSScreen.screens.first { $0.frame.minX <= ax.midX && ax.midX < $0.frame.maxX } ?? screen
                rightInsets[ObjectIdentifier(item)] = axScreen.frame.maxX - ax.maxX
            }
        } else if item.length != Self.hidingLength {
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            if frame.width > 0, frame.width < 200 {
                rightInsets[ObjectIdentifier(item)] = screen.frame.maxX - frame.maxX
            }
        }
        guard let inset = rightInsets[ObjectIdentifier(item)] else { return nil }
        let rightEdge = screen.frame.maxX - inset
        let fill = rightEdge - Self.statusAreaLeftLimit(on: screen) - 2
        return fill > 20 ? fill : nil
    }

    /// Abstand der rechten Trennerkante vom rechten Bildschirmrand, gemessen
    /// im schmalen Zustand (je Status-Item).
    private var rightInsets: [ObjectIdentifier: CGFloat] = [:]

    /// Zuletzt gemessene Breite der App-Menüs (ab linkem Bildschirmrand). Dient
    /// als Rückfall, wenn die Bedienungshilfen gerade keine Menüs liefern —
    /// direkt nach einem App-Wechsel oder wenn floosh selbst vorne ist.
    private static var lastMenuWidth: CGFloat?

    /// Wie die letzte Grenze zustande kam — fürs Diagnose-Protokoll.
    private static var lastLimitInfo = ""

    /// Lage eines eigenen Status-Symbols laut Bedienungshilfen (globale
    /// x-Koordinaten wie bei NSScreen).
    private static func axFrame(ofOwnItemLabeled label: String) -> CGRect? {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success,
              let bar else { return nil }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
        for element in (children as? [AXUIElement]) ?? [] {
            var desc: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &desc)
            guard desc as? String == label else { continue }
            var pos: CFTypeRef?
            var size: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos)
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size)
            var p = CGPoint.zero
            var s = CGSize.zero
            if let pos { AXValueGetValue(pos as! AXValue, .cgPoint, &p) }
            if let size { AXValueGetValue(size as! AXValue, .cgSize, &s) }
            return CGRect(origin: p, size: s)
        }
        return nil
    }

    /// Kurz nach dem Einklappen festhalten, wie macOS die Trenner tatsächlich
    /// ausgelegt hat — daran sieht man, ob ein Trenner ausgeblendet wurde.
    private func logLayoutSoon() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, let hiddenDivider = self.hiddenDivider else { return }
            let window = hiddenDivider.button?.window
            let windowFrame = self.frame(of: hiddenDivider) ?? .zero
            let ax = AXIsProcessTrusted() ? Self.axFrame(ofOwnItemLabeled: Self.hiddenDividerLabel) : nil
            let axToggle = AXIsProcessTrusted() ? self.axToggleFrame() : nil
            OrganizerLog.write("  Lage: Länge \(Int(hiddenDivider.length)), Fenster \(OrganizerLog.rect(windowFrame)) sichtbar \(window?.occlusionState.contains(.visible) == true ? "ja" : "nein"), AX \(ax.map(OrganizerLog.rect) ?? "–"), Pfeil AX \(axToggle.map(OrganizerLog.rect) ?? "–"), Abstände \(self.rightInsets.values.map { Int($0) })")
        }
    }

    private func axToggleFrame() -> CGRect? {
        Self.axFrame(ofOwnItemLabeled: "Versteckte Symbole zeigen") ?? Self.axFrame(ofOwnItemLabeled: "Symbole verstecken")
    }

    /// Wo der Bereich der Menüleisten-Symbole links endet: an der Notch, sonst
    /// am Ende der Menüs der gerade aktiven App (Bedienungshilfen). Ohne Notch
    /// bis zum Bildschirmrand zu rechnen wäre zu breit — macOS blendet den
    /// Trenner dann einfach aus, statt die Symbole wegzuschieben (Mac mini).
    private static func statusAreaLeftLimit(on screen: NSScreen) -> CGFloat {
        lastLimitInfo = "Bildschirm x \(Int(screen.frame.minX))…\(Int(screen.frame.maxX)), \(NSScreen.screens.count) Bildschirm(e)"
        if hasNotch(screen), let notch = screen.auxiliaryTopRightArea {
            lastLimitInfo += ", Notch ab \(Int(notch.minX))"
            return notch.minX
        }
        let front = NSWorkspace.shared.frontmostApplication
        lastLimitInfo += ", vorne: \(front?.localizedName ?? "?"), AX \(AXIsProcessTrusted() ? "ja" : "nein")"
        if AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var bar: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &bar) == .success, let bar {
                var children: CFTypeRef?
                AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
                var minX = CGFloat.greatestFiniteMagnitude
                var maxX = -CGFloat.greatestFiniteMagnitude
                for element in (children as? [AXUIElement]) ?? [] {
                    var pos: CFTypeRef?
                    var size: CFTypeRef?
                    AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos)
                    AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size)
                    var p = CGPoint.zero
                    var s = CGSize.zero
                    if let pos { AXValueGetValue(pos as! AXValue, .cgPoint, &p) }
                    if let size { AXValueGetValue(size as! AXValue, .cgSize, &s) }
                    guard s.width > 0 else { continue }
                    minX = min(minX, p.x)
                    maxX = max(maxX, p.x + s.width)
                }
                // Mit mehreren Bildschirmen liegen die Menüs evtl. auf einem
                // anderen als der Trenner — daher relativ zum eigenen
                // Bildschirm rechnen
                if maxX > minX {
                    let menuScreenMinX = NSScreen.screens
                        .first { $0.frame.minX <= minX && minX < $0.frame.maxX }?.frame.minX ?? screen.frame.minX
                    lastMenuWidth = maxX - menuScreenMinX
                    lastLimitInfo += ", Menüs \(Int(minX))…\(Int(maxX))"
                } else {
                    lastLimitInfo += ", keine Menüs"
                }
            }
        }
        if AXIsProcessTrusted(), let lastMenuWidth {
            lastLimitInfo += ", Menübreite \(Int(lastMenuWidth))"
            return screen.frame.minX + lastMenuWidth + 12
        }
        lastLimitInfo += ", Schätzung 45 %"
        // Ohne Bedienungshilfen: großzügig schätzen — App-Menüs nehmen selten
        // mehr als 45 % der Breite ein
        return screen.frame.minX + screen.frame.width * 0.45
    }

    /// Beim App-Wechsel ändern sich die Menüs links — Breite neu rechnen.
    /// Gleich und noch einmal kurz danach: Direkt nach dem Wechsel hat macOS
    /// die Menüs der neuen App oft noch nicht ausgelegt.
    private func refitAfterAppSwitch() {
        refit()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.refit()
        }
    }

    /// Eingeklappt die Trennerbreite an Menüs und Bildschirm anpassen — nur
    /// wenn sie sich spürbar geändert hat, damit nichts flackert.
    private func refit() {
        guard !isExpanded, isRunning, let hiddenDivider else { return }
        let target = fillLength(for: hiddenDivider) ?? Self.hidingLength
        guard abs(target - hiddenDivider.length) > 3 else { return }
        apply(expanded: false, always: false, quiet: true)
    }

    /// Ohne Notch regelmäßig nachrechnen: Fokuswechsel auf einen anderen
    /// Monitor, Menüs, die sich innerhalb einer App ändern, oder ein App-Wechsel,
    /// den macOS ohne Benachrichtigung abschließt.
    private func startRefitLoop() {
        refitTask?.cancel()
        refitTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, self.isRunning else { return }
                let screen = self.hiddenDivider?.button?.window?.screen ?? NSScreen.main
                if let screen, !Self.hasNotch(screen) { self.refit() }
            }
        }
    }

    func toggleFrame() -> NSRect? {
        frame(of: toggle)
    }

    private func pointerInMenuBar() -> Bool {
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) else { return false }
        return p.y >= screen.visibleFrame.maxY
    }

    /// Ist irgendwo ein Menü offen? Fensterliste ohne Inhalte (keine
    /// Bildschirmaufnahme nötig): Menüs liegen auf der Pop-up-Menü-Ebene.
    private static func menuIsOpen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return list.contains { ($0[kCGWindowLayer as String] as? Int) == menuLevel }
    }

    // MARK: Kontextmenü

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: isExpanded ? "Verstecken" : "Versteckte zeigen",
                     action: #selector(menuToggle), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Auch „Immer versteckt“ zeigen",
                     action: #selector(menuShowAll), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "So ordnest du Symbole an …",
                     action: #selector(menuHelp), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Einstellungen …",
                     action: #selector(menuSettings), keyEquivalent: "").target = self
        toggle?.menu = menu
        toggle?.button?.performClick(nil)
        toggle?.menu = nil
    }

    @objc private func menuToggle() { if isExpanded { collapse() } else { expand() } }
    @objc private func menuShowAll() { apply(expanded: true, always: true) }
    @objc private func menuSettings() { SettingsLauncher.open() }

    @objc private func menuHelp() {
        expand(includingAlwaysHidden: true)
        let alert = NSAlert()
        alert.messageText = "Symbole in der Menüleiste anordnen"
        alert.informativeText = """
        Halte ⌘ gedrückt und ziehe Symbole in der Menüleiste:

        • rechts vom Pfeil ‹ – immer sichtbar
        • zwischen │ und ‹ – versteckt, kommen per Klick auf den Pfeil
        • links von ┆ – immer versteckt, nur per ⌥-Klick auf den Pfeil

        Zum Anordnen sind gerade alle Bereiche ausgeklappt.
        """
        alert.addButton(withTitle: "Verstanden")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        scheduleCollapse()
    }

    // MARK: Startpositionen

    /// Beim allerersten Einschalten sinnvolle Plätze vorgeben. macOS merkt sich
    /// Positionen als Abstand vom rechten Bildschirmrand unter
    /// „NSStatusItem Preferred Position <autosaveName>" und liest sie beim
    /// Anlegen eines Symbols. Ohne Vorgabe landen neue Symbole ganz links — auf
    /// MacBooks mit Notch dann oft unsichtbar hinter der Notch.
    ///
    /// Ergebnis: floosh und der Pfeil ganz rechts (vor Siri/Kontrollzentrum),
    /// alle übrigen Apps zunächst im versteckten Bereich.
    /// - Returns: `true`, wenn die Position des floosh-Symbols neu gesetzt wurde.
    @discardableResult
    private static func seedPositionsIfNeeded() -> Bool {
        let d = UserDefaults.standard
        func seed(_ name: String, _ value: Double) -> Bool {
            let key = "NSStatusItem Preferred Position \(name)"
            guard d.object(forKey: key) == nil else { return false }
            d.set(value, forKey: key)
            return true
        }
        let main = seed("digital.jrn.floosh.status", 205)
        _ = seed("digital.jrn.floosh.organizer.toggle", 215)
        _ = seed("digital.jrn.floosh.organizer.hidden", 225)
        _ = seed("digital.jrn.floosh.organizer.always", 6000)
        return main
    }

    // MARK: Bilder

    /// Schmaler senkrechter Strich (durchgezogen bzw. gestrichelt) als Trenner.
    private static func dividerImage(dashed: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 6, height: 16), flipped: false) { rect in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.midX, y: 2))
            path.line(to: NSPoint(x: rect.midX, y: rect.maxY - 2))
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            if dashed { path.setLineDash([2, 2.5], count: 2, phase: 0) }
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Diagnose-Protokoll des Organizers unter ~/Library/Logs/floosh-organizer.log
/// (bleibt klein: wird ab 256 KB neu begonnen).
@MainActor
enum OrganizerLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/floosh-organizer.log")

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > 256_000 {
            try? fm.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    static func num(_ value: CGFloat?) -> String {
        value.map { String(Int($0)) } ?? "–"
    }

    static func rect(_ r: CGRect) -> String {
        "x \(Int(r.minX))…\(Int(r.maxX)) (\(Int(r.width)))"
    }
}
