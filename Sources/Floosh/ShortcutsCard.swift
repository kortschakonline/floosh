import SwiftUI

/// Karte mit den ausgewählten Kurzbefehlen als Knöpfe.
struct ShortcutsCard: View {
    let engine: StatsEngine
    @Bindable var shortcuts: ShortcutsService

    static let tint = Color(red: 0.36, green: 0.68, blue: 0.96) // Kurzbefehle-Blau

    private var size: CardSize { engine.cardSize }

    var body: some View {
        VStack(alignment: .leading, spacing: size.spacing) {
            header
            if let error = shortcuts.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            if shortcuts.chosen.isEmpty {
                empty
            } else {
                buttons
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(size.padding)
        .cardGlass(cornerRadius: size.cornerRadius)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            CardIcon(symbol: "square.stack.3d.up", tint: Self.tint, size: size)

            VStack(alignment: .leading, spacing: 1) {
                Text("Kurzbefehle")
                    .font(size.titleFont)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if shortcuts.running != nil {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var subtitle: String {
        if let running = shortcuts.running { return "läuft: \(running)" }
        let count = shortcuts.chosen.count
        return count == 0 ? "keine ausgewählt" : "\(count) \(count == 1 ? "Kurzbefehl" : "Kurzbefehle")"
    }

    private var empty: some View {
        Text("Unter Einstellungen → Kurzbefehle auswählen, welche hier als Knopf erscheinen.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Zwei Knöpfe nebeneinander — mehr wird bei den Kartenbreiten zu eng.
    private var buttons: some View {
        let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(shortcuts.chosen, id: \.self) { name in
                Button {
                    shortcuts.run(name)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(.system(size: size.glyphFont - 1))
                            .foregroundStyle(Self.tint)
                        Text(name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Self.tint.opacity(0.14), in: .rect(cornerRadius: 8))
                    .contentShape(.rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(shortcuts.running != nil)
                .help("Kurzbefehl ausführen: \(name)")
            }
        }
    }
}
