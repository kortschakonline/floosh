import AppKit
import ApplicationServices

// MARK: - Sicherer Start

/// Erkennt, wenn floosh mehrmals hintereinander kurz nach dem Start stirbt,
/// und startet dann ohne die Teile, die eigene Fenster bauen (Desktop-Panel,
/// Island, Menüleisten-Organizer). Ohne diese Bremse kann ein einziger
/// Fehler beim Anmelden floosh dauerhaft unerreichbar machen — so geschehen
/// mit 1.14.5 am Mac mini (Desktop-Panel, Layout-Rekursion).
///
/// Prinzip: Beim Start wird ein Zeitstempel gesetzt, nach `stableAfter`
/// Sekunden oder beim regulären Beenden wieder gelöscht. Steht er beim
/// nächsten Start noch da, ist der Vorgänger früh gestorben.
@MainActor
enum SafeStart {

    private static let startedKey = "safe.startedAt"
    private static let crashesKey = "safe.quickCrashes"
    private static let disabledKey = "safe.disabledParts"
    /// So lange muss ein Start überleben, um als stabil zu gelten.
    private static let stableAfter: Duration = .seconds(45)
    /// Ab so vielen frühen Abstürzen in Folge wird abgesichert gestartet.
    private static let threshold = 2

    /// Teile, die bei diesem Start abgeschaltet wurden (für den Hinweis).
    private(set) static var disabledThisLaunch: [String] = []

    /// Ganz am Anfang aufrufen — bevor Panel, Island oder Organizer ihre
    /// Einstellungen lesen.
    static func evaluate() {
        let defaults = UserDefaults.standard
        var crashes = defaults.integer(forKey: crashesKey)
        if defaults.object(forKey: startedKey) != nil {
            crashes += 1
        } else {
            crashes = 0
        }
        defaults.set(crashes, forKey: crashesKey)

        if crashes >= threshold {
            let parts: [(key: String, title: String)] = [
                ("panel.enabled", "Desktop-Panel"),
                ("island.enabled", "Island"),
                ("organizer.enabled", "Symbole verstecken"),
            ]
            for part in parts where (defaults.object(forKey: part.key) as? Bool) ?? (part.key == "island.enabled") {
                defaults.set(false, forKey: part.key)
                disabledThisLaunch.append(part.title)
            }
            defaults.set(disabledThisLaunch, forKey: disabledKey)
            // Neu zählen — reicht das Abschalten nicht, greift die Bremse beim
            // übernächsten Start wieder, ohne endlos zu warnen
            defaults.set(0, forKey: crashesKey)
        }

        defaults.set(Date().timeIntervalSince1970, forKey: startedKey)
        Task { @MainActor in
            try? await Task.sleep(for: stableAfter)
            markStable()
        }
    }

    /// Start gilt als gelungen (nach `stableAfter` oder beim Beenden).
    static func markStable() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: startedKey)
        defaults.set(0, forKey: crashesKey)
    }

    /// Nach dem Start einmal erklären, was abgeschaltet wurde.
    static func explainIfNeeded() {
        guard !disabledThisLaunch.isEmpty else { return }
        let list = disabledThisLaunch.joined(separator: ", ")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let alert = NSAlert()
            alert.messageText = "floosh ist abgesichert gestartet"
            alert.informativeText = "floosh ist zuletzt mehrmals kurz nach dem Start abgestürzt. Damit es erreichbar bleibt, ist jetzt ausgeschaltet: \(list).\n\nDu kannst es in den Einstellungen wieder einschalten. Hilfreich für die Fehlersuche: Einstellungen → Allgemein → „Diagnose kopieren\u{201C}."
            alert.addButton(withTitle: "Einstellungen öffnen")
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                SettingsLauncher.open()
            }
        }
    }
}

// MARK: - Symbol im Überlauf

/// Erkennt, wenn macOS 27 das floosh-Symbol in den Überlauf « der Menüleiste
/// legt (volle Leiste, oder floosh gilt nach einem Update als „neue" App).
/// Dann ist floosh scheinbar weg — deshalb einmal je Start darauf hinweisen.
@MainActor
enum StatusItemWatch {

    private static var warned = false

    /// Liegt das Symbol sichtbar in der Menüleiste? `nil` = nicht feststellbar.
    /// Im Überlauf meldet macOS das Fenster des Knopfs als verdeckt und
    /// am linken Bildschirmrand (x 0, Mac mini, macOS 27.2).
    static func isVisible(_ item: NSStatusItem?) -> Bool? {
        guard let window = item?.button?.window else { return nil }
        let visible = window.occlusionState.contains(.visible)
        let frame = window.frame
        return visible && frame.width > 0 && frame.minX > 1
    }

    /// Ein paar Sekunden nach dem Start (und noch einmal etwas später)
    /// prüfen — nicht bei gesperrtem Bildschirm.
    static func start(item: @escaping () -> NSStatusItem?) {
        Task { @MainActor in
            for delay in [20, 60] {
                try? await Task.sleep(for: .seconds(delay))
                guard !warned, !screenIsLocked() else { continue }
                let frame = item()?.button?.window?.frame ?? .zero
                OrganizerLog.write("Symbol-Prüfung: \(isVisible(item()).map { $0 ? "sichtbar" : "verdeckt" } ?? "unbekannt") (Fenster x \(Int(frame.minX.isFinite ? frame.minX : -1)), Breite \(Int(frame.width.isFinite ? frame.width : -1)))")
                // Zweimal kurz hintereinander verdeckt, damit ein Wechsel des
                // Space oder ein Vollbild-Programm nicht falsch alarmiert
                guard isVisible(item()) == false else { continue }
                try? await Task.sleep(for: .seconds(3))
                guard isVisible(item()) == false, !screenIsLocked() else { continue }
                warn()
            }
        }
    }

    static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool == true
            || session[kCGSessionOnConsoleKey as String] as? Bool == false
    }

    private static func warn() {
        warned = true
        let alert = NSAlert()
        alert.messageText = "floosh liegt im Überlauf der Menüleiste"
        alert.informativeText = "macOS hat das floosh-Symbol in den Bereich « rechts in der Menüleiste gelegt — meist, weil die Leiste voll ist oder floosh nach einem Update als neue App gilt.\n\nSo holst du es zurück: auf « klicken, ⌘ gedrückt halten und das floosh-Symbol in die Menüleiste ziehen, am besten weit nach rechts."
        alert.addButton(withTitle: "Verstanden")
        alert.addButton(withTitle: "Einstellungen öffnen")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            SettingsLauncher.open()
        }
    }
}

// MARK: - Diagnose

/// Sammelt alles, was bei der Fehlersuche hilft, als Text für die
/// Zwischenablage: Version, Bildschirme, Rechte, Einstellungen, die letzten
/// Absturzberichte (gekürzt) und das Organizer-Protokoll.
@MainActor
enum Diagnostics {

    static func report() -> String {
        var lines: [String] = []
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        lines.append("floosh \(version) (\(build)) · \(ProcessInfo.processInfo.operatingSystemVersionString) · \(modelIdentifier())")
        lines.append("Systemlaufzeit: \(Int(ProcessInfo.processInfo.systemUptime / 60)) min")

        lines.append("")
        lines.append("Bildschirme (getrennte Spaces: \(NSScreen.screensHaveSeparateSpaces ? "ja" : "nein")):")
        for screen in NSScreen.screens {
            let notch = screen.safeAreaInsets.top > 0 ? ", Notch" : ""
            lines.append("  \(screen.localizedName): \(rect(screen.frame)), sichtbar \(rect(screen.visibleFrame)), \(screen.backingScaleFactor)x\(notch)")
        }

        lines.append("")
        lines.append("Rechte: Bedienungshilfen \(AXIsProcessTrusted() ? "ja" : "nein"), Bildschirmaufnahme \(CGPreflightScreenCaptureAccess() ? "ja" : "nein")")
        lines.append("Lüfter-Helfer: \(FanService.shared.helperState), Modus \(FanService.shared.mode.rawValue)")
        let symbol = StatusItemWatch.isVisible(MenuBarController.shared?.statusItemForDiagnostics)
        lines.append("Menüleisten-Symbol: \(symbol.map { $0 ? "sichtbar" : "verdeckt/Überlauf" } ?? "unbekannt")")

        lines.append("")
        lines.append("Einstellungen:")
        let defaults = UserDefaults.standard
        let keys = defaults.dictionaryRepresentation().keys
            .filter { ["panel.", "island.", "organizer.", "ds.fan", "ds.menu", "safe."].contains(where: $0.hasPrefix) }
            .sorted()
        for key in keys {
            let value = defaults.object(forKey: key)
            // Lüfterkurve ist binär — nur die Größe zeigen
            let text = (value as? Data).map { "<\($0.count) Bytes>" } ?? String(describing: value ?? "–")
            lines.append("  \(key) = \(text.replacingOccurrences(of: "\n", with: " "))")
        }

        lines.append("")
        lines.append("Absturzberichte:")
        let reports = crashReports()
        if reports.isEmpty { lines.append("  keine") }
        lines.append(contentsOf: reports)

        lines.append("")
        lines.append("Organizer-Protokoll (Ende):")
        let log = (try? String(contentsOf: OrganizerLog.url, encoding: .utf8)) ?? "kein Protokoll"
        lines.append(contentsOf: log.split(separator: "\n").suffix(40).map { "  " + $0 })
        return lines.joined(separator: "\n")
    }

    static func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report(), forType: .string)
    }

    /// Die letzten fünf floosh-Absturzberichte, je eine kurze Zusammenfassung.
    private static func crashReports() -> [String] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("floosh-") && $0.pathExtension == "ips" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(5)
        return files.map { url in
            "  \(url.lastPathComponent): \(summarize(url) ?? "nicht lesbar")"
        }
    }

    /// Eine .ips-Datei: erste Zeile Kopf (JSON), Rest der Bericht (JSON).
    private static func summarize(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let split = text.firstIndex(of: "\n") else { return nil }
        let head = (try? JSONSerialization.jsonObject(with: Data(text[..<split].utf8))) as? [String: Any]
        guard let body = (try? JSONSerialization.jsonObject(with: Data(text[text.index(after: split)...].utf8))) as? [String: Any]
        else { return nil }
        var parts: [String] = []
        if let version = head?["app_version"] as? String { parts.append(version) }
        if let exception = body["exception"] as? [String: Any] {
            parts.append([exception["type"], exception["signal"], exception["message"]]
                .compactMap { $0 as? String }.joined(separator: " "))
        }
        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        let threads = (body["threads"] as? [[String: Any]]) ?? []
        let faulting = body["faultingThread"] as? Int ?? 0
        if faulting < threads.count {
            let thread = threads[faulting]
            if let recursion = (thread["recursionInfoArray"] as? [[String: Any]])?.first,
               let depth = recursion["depth"] as? Int {
                parts.append("Rekursion \(depth)×")
            }
            // Die eigenen Funktionen im Stapel sagen am meisten
            let own = ((thread["frames"] as? [[String: Any]]) ?? []).compactMap { frame -> String? in
                guard let index = frame["imageIndex"] as? Int, index < images.count,
                      images[index]["name"] as? String == "floosh",
                      let symbol = frame["symbol"] as? String, !symbol.hasPrefix("<") else { return nil }
                return symbol
            }
            if !own.isEmpty { parts.append("floosh: " + own.prefix(6).joined(separator: " ← ")) }
        }
        return parts.joined(separator: " · ")
    }

    private static func modelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    private static func rect(_ r: CGRect) -> String {
        guard r.minX.isFinite, r.width.isFinite else { return "?" }
        return "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))"
    }
}
