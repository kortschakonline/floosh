import Foundation
import AppKit
import Observation

/// Zugriff auf die Kurzbefehle des Benutzers über `/usr/bin/shortcuts`.
///
/// Warum die Kommandozeile und nicht `shortcuts://run-shortcut?name=…`:
/// Das URL-Schema holt die Kurzbefehle-App nach vorn, das CLI führt still
/// im Hintergrund aus — für einen Knopf in der Menüleiste das Richtige.
/// Ohne Sandbox ist beides erlaubt.
@MainActor
@Observable
final class ShortcutsService {

    static let shared = ShortcutsService()

    private static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    /// Alle Kurzbefehle des Benutzers, alphabetisch.
    private(set) var available: [String] = []
    /// Läuft gerade ein Kurzbefehl? (Name, für die Rückmeldung in der Karte)
    private(set) var running: String?
    /// Letzter Fehler, kurz in der Karte sichtbar.
    private(set) var lastError: String?

    /// Welche Kurzbefehle als Knöpfe erscheinen — Reihenfolge zählt.
    var chosen: [String] {
        didSet { defaults.set(chosen, forKey: "shortcuts.chosen") }
    }
    /// Karte im Dropdown zeigen.
    var showInDropdown: Bool {
        didSet { defaults.set(showInDropdown, forKey: "shortcuts.inDropdown") }
    }

    private let defaults = UserDefaults.standard
    private var noticeTask: Task<Void, Never>?

    private init() {
        chosen = defaults.stringArray(forKey: "shortcuts.chosen") ?? []
        showInDropdown = defaults.object(forKey: "shortcuts.inDropdown") as? Bool ?? false
    }

    /// Gibt es die Kurzbefehle-Kommandozeile überhaupt? (Sie fehlt auf
    /// Systemen ohne Kurzbefehle-App.)
    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: Self.tool.path)
    }

    /// Liste neu einlesen — beim Öffnen der Einstellungen und auf Knopfdruck.
    func refresh() async {
        guard isAvailable else { return }
        let names = await Self.run(arguments: ["list"])
        switch names {
        case .success(let text):
            available = text
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            // Inzwischen gelöschte Kurzbefehle nicht als tote Knöpfe stehen lassen
            let vanished = chosen.filter { !available.contains($0) }
            if !vanished.isEmpty {
                chosen.removeAll { vanished.contains($0) }
            }
        case .failure(let message):
            show(error: message)
        }
    }

    /// Führt einen Kurzbefehl aus.
    func run(_ name: String) {
        guard running == nil else { return }
        running = name
        Task {
            let result = await Self.run(arguments: ["run", name])
            running = nil
            if case .failure(let message) = result {
                show(error: message)
            }
        }
    }

    func toggle(_ name: String) {
        if let index = chosen.firstIndex(of: name) {
            chosen.remove(at: index)
        } else {
            chosen.append(name)
        }
    }

    func move(_ name: String, by offset: Int) {
        guard let from = chosen.firstIndex(of: name) else { return }
        let to = from + offset
        guard chosen.indices.contains(to) else { return }
        chosen.swapAt(from, to)
    }

    // MARK: Intern

    private func show(error: String) {
        lastError = error
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.lastError = nil
        }
    }

    private enum Outcome {
        case success(String)
        case failure(String)
    }

    /// `shortcuts` aufrufen, ohne den Hauptthread zu blockieren.
    private static func run(arguments: [String]) async -> Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = tool
                process.arguments = arguments
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failure(error.localizedDescription))
                    return
                }
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: .success(String(decoding: stdout, as: UTF8.self)))
                } else {
                    let message = String(decoding: stderr, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: .failure(message.isEmpty ? "Kurzbefehl fehlgeschlagen" : message))
                }
            }
        }
    }
}
