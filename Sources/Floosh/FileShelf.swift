import SwiftUI
import AppKit
import Observation
import QuickLookThumbnailing

/// Ein Eintrag der Ablage: eine Referenz auf eine Datei oder einen Ordner.
///
/// floosh kopiert nichts — die Datei bleibt, wo sie ist; die Ablage merkt sich
/// nur den Ort. Gespeichert wird als Bookmark, damit Umbenennen oder
/// Verschieben den Eintrag nicht verliert.
struct ShelfItem: Identifiable, Equatable {
    let id: UUID
    var url: URL
    var addedAt: Date
    var isDirectory: Bool
    /// Beim letzten Prüflauf nicht mehr auffindbar (gelöscht/ausgeworfen).
    var missing: Bool = false

    var name: String { url.lastPathComponent }
}

/// Die Ablage: Dateien kurz parken und später wieder herausziehen.
@MainActor
@Observable
final class FileShelf {

    static let shared = FileShelf()
    /// Obergrenze, damit Karte und Panel nicht unbegrenzt wachsen.
    static let maxItems = 20

    private(set) var items: [ShelfItem] = []
    /// Kurzer Hinweis in der Karte (z. B. „Ablage ist voll").
    private(set) var notice: String?

    var showInDropdown: Bool {
        didSet { defaults.set(showInDropdown, forKey: "shelf.inDropdown") }
    }
    var clearOnQuit: Bool {
        didSet { defaults.set(clearOnQuit, forKey: "shelf.clearOnQuit") }
    }

    private let defaults = UserDefaults.standard
    private var noticeTask: Task<Void, Never>?

    init() {
        showInDropdown = defaults.object(forKey: "shelf.inDropdown") as? Bool ?? true
        clearOnQuit = defaults.object(forKey: "shelf.clearOnQuit") as? Bool ?? false
        load()
    }

    var isFull: Bool { items.count >= Self.maxItems }

    // MARK: Ändern

    /// Übernimmt Datei-URLs (Duplikate und Nicht-Dateien werden übersprungen).
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        var added = 0
        var skippedFull = false
        for url in urls {
            let standardized = url.standardizedFileURL
            guard standardized.isFileURL,
                  FileManager.default.fileExists(atPath: standardized.path) else { continue }
            guard !items.contains(where: { $0.url == standardized }) else { continue }
            guard items.count < Self.maxItems else { skippedFull = true; break }
            items.insert(ShelfItem(id: UUID(),
                                   url: standardized,
                                   addedAt: Date(),
                                   isDirectory: standardized.hasDirectoryPath),
                         at: 0)
            added += 1
        }
        if added > 0 { save() }
        if skippedFull {
            show(notice: "Ablage ist voll (\(Self.maxItems) Einträge)")
        } else if added == 0, !urls.isEmpty {
            show(notice: "Schon in der Ablage")
        }
        return added
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    /// Prüft, welche Einträge es noch gibt — beim Öffnen der Karte.
    func refresh() {
        var changed = false
        for i in items.indices {
            let gone = !FileManager.default.fileExists(atPath: items[i].url.path)
            if items[i].missing != gone {
                items[i].missing = gone
                changed = true
            }
        }
        if changed { save() }
    }

    // MARK: Aktionen

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Datei-URLs aus der Zwischenablage übernehmen (in Finder ⌘C).
    @discardableResult
    func pasteFromClipboard() -> Int {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            show(notice: "Keine Datei in der Zwischenablage")
            return 0
        }
        return add(urls)
    }

    /// „Hinzufügen …" — Dateiauswahl, falls Ziehen nicht möglich ist.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Zur Ablage"
        panel.message = "Dateien für die Ablage auswählen"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            add(panel.urls)
        }
    }

    private func show(notice text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Persistenz

    private struct StoredItem: Codable {
        var id: UUID
        var bookmark: Data?
        var path: String
        var addedAt: Date
        var isDirectory: Bool
    }

    private func save() {
        let stored = items.map { item in
            StoredItem(id: item.id,
                       bookmark: try? item.url.bookmarkData(options: .minimalBookmark),
                       path: item.url.path,
                       addedAt: item.addedAt,
                       isDirectory: item.isDirectory)
        }
        defaults.set(try? JSONEncoder().encode(stored), forKey: "shelf.items")
    }

    private func load() {
        guard let data = defaults.data(forKey: "shelf.items"),
              let stored = try? JSONDecoder().decode([StoredItem].self, from: data) else { return }
        items = stored.map { entry in
            // Bookmark zuerst — es findet die Datei auch nach Umbenennen oder
            // Verschieben; sonst der gespeicherte Pfad.
            var url = URL(fileURLWithPath: entry.path)
            var stale = false
            if let bookmark = entry.bookmark,
               let resolved = try? URL(resolvingBookmarkData: bookmark,
                                       options: [.withoutUI],
                                       relativeTo: nil,
                                       bookmarkDataIsStale: &stale) {
                url = resolved
            }
            return ShelfItem(id: entry.id,
                             url: url.standardizedFileURL,
                             addedAt: entry.addedAt,
                             isDirectory: entry.isDirectory,
                             missing: !FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// Beim Beenden räumen, falls gewünscht.
    func clearOnQuitIfNeeded() {
        guard clearOnQuit, !items.isEmpty else { return }
        clear()
    }
}

// MARK: - Vorschaubilder

/// Thumbnails aus QuickLook, im Speicher gehalten. Die Erzeugung liefert PNG-
/// Daten zurück (`Data` ist Sendable) — das Bild entsteht erst wieder hier
/// auf dem MainActor.
@MainActor
final class ThumbnailCache {

    static let shared = ThumbnailCache()

    private var cache: [String: NSImage] = [:]
    private var running: Set<String> = []

    func cached(_ url: URL, size: CGFloat) -> NSImage? {
        cache[key(url, size)]
    }

    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let key = key(url, size)
        if let hit = cache[key] { return hit }
        guard !running.contains(key) else { return nil }
        running.insert(key)
        defer { running.remove(key) }

        let image: NSImage
        if let data = await Self.render(url: url, points: size), let png = NSImage(data: data) {
            image = png
        } else {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        cache[key] = image
        return image
    }

    private func key(_ url: URL, _ size: CGFloat) -> String {
        "\(url.path)@\(Int(size))"
    }

    private nonisolated static func render(url: URL, points: CGFloat) async -> Data? {
        await withCheckedContinuation { continuation in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: points, height: points),
                scale: 2,
                representationTypes: .all
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                guard let cgImage = representation?.cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                continuation.resume(returning: bitmap.representation(using: .png, properties: [:]))
            }
        }
    }
}
