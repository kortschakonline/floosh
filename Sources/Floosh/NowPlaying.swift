import AppKit
import Observation

/// „Läuft gerade" für Apple Music und Spotify — per AppleScript.
///
/// Die systemweite Wiedergabe-Schnittstelle (MediaRemote) ist seit macOS 15.4
/// für fremde Apps gesperrt; die Umwege darum sind auf Beta-Systemen
/// wackelig. AppleScript ist offiziell und stabil, deckt aber nur die beiden
/// Player-Apps ab (keine Browser). macOS fragt beim ersten Mal einmal pro
/// Player nach der Erlaubnis (Automation).
///
/// Wichtig: Nur Apps ansprechen, die *laufen* — ein `tell application` an
/// eine geschlossene App würde sie starten, an eine nicht installierte App
/// fragt macOS „Wo ist …?".
@MainActor
@Observable
final class NowPlaying {
    static let shared = NowPlaying()

    enum Player: String {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"

        var title: String { self == .music ? "Musik" : "Spotify" }
    }

    struct Track: Equatable {
        var player: Player
        var title: String
        var artist: String
        var album: String
        var isPlaying: Bool
        var artworkURL: URL?
    }

    private(set) var track: Track?
    private(set) var artwork: NSImage?
    /// macOS hat die Steuerung verweigert (Automation in den Systemeinstellungen aus).
    private(set) var permissionDenied = false

    private var loop: Task<Void, Never>?
    private var lastArtworkKey: String?

    /// Abfragen nur, solange jemand hinsieht (Island offen).
    func setActive(_ active: Bool) {
        if active {
            guard loop == nil else { return }
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    self?.refresh()
                    try? await Task.sleep(for: .seconds(1.5))
                }
            }
        } else {
            loop?.cancel()
            loop = nil
        }
    }

    func refresh() {
        // Spielende App bevorzugen, sonst die zuletzt gefundene
        let candidates = [Player.spotify, .music].filter(isRunning)
        var found: Track?
        for player in candidates {
            if let t = query(player) {
                if t.isPlaying { found = t; break }
                if found == nil { found = t }
            }
        }
        if found != track { track = found }
        updateArtwork()
    }

    func playPause() { command("playpause") }
    func next() { command("next track") }
    func previous() { command("previous track") }

    // MARK: AppleScript

    private func isRunning(_ player: Player) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.rawValue).isEmpty
    }

    private func command(_ verb: String) {
        guard let player = track?.player, isRunning(player) else { return }
        _ = run("tell application id \"\(player.rawValue)\" to \(verb)")
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.refresh()
        }
    }

    private func query(_ player: Player) -> Track? {
        let artwork = player == .spotify ? " & \"\\n\" & (artwork url of current track)" : ""
        let source = """
        tell application id "\(player.rawValue)"
            if player state is stopped then return ""
            return (player state as text) & "\\n" & (name of current track) & "\\n" & (artist of current track) & "\\n" & (album of current track)\(artwork)
        end tell
        """
        guard let text = run(source), !text.isEmpty else { return nil }
        let parts = text.components(separatedBy: "\n")
        guard parts.count >= 4 else { return nil }
        return Track(player: player, title: parts[1], artist: parts[2], album: parts[3],
                     isPlaying: parts[0] == "playing",
                     artworkURL: parts.count > 4 ? URL(string: parts[4]) : nil)
    }

    private func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            // -1743: Nutzer hat die Automation nicht erlaubt
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 { permissionDenied = true }
            return nil
        }
        permissionDenied = false
        return result?.stringValue
    }

    /// Cover nur bei Titelwechsel laden: Spotify liefert eine URL, Apple Music
    /// die Bilddaten des ersten Covers.
    private func updateArtwork() {
        guard let track else { artwork = nil; lastArtworkKey = nil; return }
        let key = "\(track.player.rawValue)|\(track.title)|\(track.album)"
        guard key != lastArtworkKey else { return }
        lastArtworkKey = key
        artwork = nil
        switch track.player {
        case .spotify:
            guard let url = track.artworkURL else { return }
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = NSImage(data: data) else { return }
                if self?.lastArtworkKey == key { self?.artwork = image }
            }
        case .music:
            var error: NSDictionary?
            let script = NSAppleScript(source: """
            tell application id "com.apple.Music" to get data of artwork 1 of current track
            """)
            if let descriptor = script?.executeAndReturnError(&error), error == nil {
                artwork = NSImage(data: descriptor.data)
            }
        }
    }
}
