import AppKit
import Observation

/// Prüft die GitHub-Releases auf eine neuere Version. Kein Auto-Install —
/// der Nutzer bekommt einen Hinweis und lädt das DMG bzw. öffnet die
/// Release-Seite. Erwartet Releases wie sie `Tools/release.sh` anlegt:
/// Tag `v<version>`, Asset `floosh-<version>.dmg`.
@MainActor
@Observable
final class UpdateChecker {

    static let shared = UpdateChecker()
    static let repository = "kortschakonline/floosh"

    struct Release: Equatable {
        let version: String
        let tag: String
        let pageURL: URL
        let downloadURL: URL?
        let notes: String
        let publishedAt: Date?
    }

    /// Version aus dem Bundle; der nackte Debug-Binary hat keine.
    static var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private(set) var latest: Release?
    private(set) var lastChecked: Date?
    private(set) var isChecking = false
    private(set) var lastError: String?

    var automatic: Bool {
        didSet {
            defaults.set(automatic, forKey: "ds.updateAuto")
            if automatic { startLoop() } else { stopLoop() }
        }
    }
    var skippedVersion: String? {
        didSet { defaults.set(skippedVersion, forKey: "ds.updateSkip") }
    }

    /// Neuere Version, die nicht übersprungen wurde.
    var available: Release? {
        guard let latest, let current = Self.currentVersion,
              Self.isNewer(latest.version, than: current),
              latest.version != skippedVersion else { return nil }
        return latest
    }

    private let defaults = UserDefaults.standard
    private var loop: Task<Void, Never>?
    private let interval: Duration = .seconds(6 * 3600)

    init() {
        automatic = defaults.object(forKey: "ds.updateAuto") as? Bool ?? true
        skippedVersion = defaults.string(forKey: "ds.updateSkip")
    }

    // MARK: Zeitplan

    /// Kurz nach dem Start prüfen, dann alle sechs Stunden — nur aus dem
    /// Bundle heraus, sonst würde jeder Release als „neuer" gelten.
    func startLoop() {
        guard automatic, loop == nil, Self.currentVersion != nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                await self?.check()
                guard let self else { return }
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    private func stopLoop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: Prüfung

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        lastError = nil

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("floosh/\(Self.currentVersion ?? "dev")", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CheckError.badResponse }
            guard http.statusCode == 200 else { throw CheckError.status(http.statusCode) }
            let dto = try JSONDecoder().decode(ReleaseDTO.self, from: data)
            latest = Release(
                version: Self.normalized(dto.tag_name),
                tag: dto.tag_name,
                pageURL: dto.html_url,
                downloadURL: dto.assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.browser_download_url,
                notes: dto.body ?? "",
                publishedAt: dto.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }
            )
            lastChecked = Date()
        } catch {
            lastError = (error as? CheckError)?.description ?? error.localizedDescription
        }
    }

    func skip(_ release: Release) {
        skippedVersion = release.version
    }

    func openDownload(_ release: Release) {
        NSWorkspace.shared.open(release.downloadURL ?? release.pageURL)
    }

    func openPage(_ release: Release) {
        NSWorkspace.shared.open(release.pageURL)
    }

    // MARK: Versionen

    /// "v1.3.0" → "1.3.0"
    static func normalized(_ tag: String) -> String {
        String(tag.drop { $0 == "v" || $0 == "V" || $0 == " " })
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = components(a), pb = components(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        normalized(version).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    // MARK: Intern

    private enum CheckError: Error, CustomStringConvertible {
        case badResponse
        case status(Int)
        var description: String {
            switch self {
            case .badResponse: "Unerwartete Antwort von GitHub"
            case .status(let code): code == 404 ? "Noch kein Release vorhanden" : "GitHub antwortet mit HTTP \(code)"
            }
        }
    }

    private struct ReleaseDTO: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let html_url: URL
        let body: String?
        let published_at: String?
        let assets: [Asset]
    }
}
