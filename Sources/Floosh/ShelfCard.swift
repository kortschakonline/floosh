import SwiftUI
import AppKit

/// Die Ablage-Karte: Dateien hineinziehen, parken und später wieder
/// herausziehen. Die Dateien bleiben an ihrem Ort — die Karte hält nur
/// Verweise.
struct ShelfCard: View {
    let engine: StatsEngine
    @Bindable var shelf: FileShelf

    static let tint = Color(red: 0.98, green: 0.45, blue: 0.66) // Rosé

    @State private var isTargeted = false

    private var size: CardSize { engine.cardSize }
    private var thumbSize: CGFloat {
        switch size {
        case .small: 40
        case .medium: 48
        case .large: 58
        }
    }
    private var itemWidth: CGFloat { thumbSize + 14 }

    var body: some View {
        VStack(alignment: .leading, spacing: size.spacing) {
            header
            if shelf.items.isEmpty {
                dropHint
            } else {
                grid
            }
            if let notice = shelf.notice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(size.padding)
        .cardGlass(tint: isTargeted ? Self.tint.opacity(0.18) : nil,
                   cornerRadius: size.cornerRadius)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: size.cornerRadius)
                    .strokeBorder(Self.tint.opacity(0.8), lineWidth: 2)
            }
        }
        // Die ganze Karte ist Ziel — nicht nur der leere Bereich
        .dropDestination(for: URL.self) { urls, _ in
            shelf.add(urls) > 0
        } isTargeted: { targeted in
            if targeted { MenuBarController.shared?.dragEnteredPanel() }
            withAnimation(.snappy(duration: 0.15)) { isTargeted = targeted }
        }
        .onAppear { shelf.refresh() }
    }

    // MARK: Kopfzeile

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            CardIcon(symbol: shelf.items.isEmpty ? "tray" : "tray.full",
                     tint: Self.tint, size: size)

            VStack(alignment: .leading, spacing: 1) {
                Text("Ablage")
                    .font(size.titleFont)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                withAnimation(.snappy(duration: 0.2)) { _ = shelf.pasteFromClipboard() }
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 14, height: 14)
            }
            .compatGlassButton()
            .controlSize(.small)
            .help("Datei aus der Zwischenablage einfügen (in Finder ⌘C)")

            Button {
                shelf.chooseFiles()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 14, height: 14)
            }
            .compatGlassButton()
            .controlSize(.small)
            .help("Dateien auswählen …")

            if !shelf.items.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { shelf.clear() }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 14, height: 14)
                }
                .compatGlassButton()
                .controlSize(.small)
                .help("Ablage leeren")
            }
        }
    }

    private var subtitle: String {
        let count = shelf.items.count
        switch count {
        case 0: return "Dateien hierher ziehen"
        case 1: return "1 Eintrag"
        default: return "\(count) Einträge"
        }
    }

    // MARK: Inhalt

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(isTargeted ? Self.tint : Color.secondary.opacity(0.4))
            .frame(height: thumbSize + 10)
            .overlay {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 12, weight: .medium))
                    Text("Dateien hierher ziehen")
                        .font(.caption2)
                }
                .foregroundStyle(isTargeted ? Self.tint : .secondary)
            }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: itemWidth), spacing: 8)],
                  alignment: .leading, spacing: 8) {
            ForEach(shelf.items) { item in
                ShelfItemView(item: item, thumbSize: thumbSize, width: itemWidth)
                    .contextMenu {
                        Button("Öffnen") { shelf.open(item) }
                            .disabled(item.missing)
                        Button("Im Finder zeigen") { shelf.reveal(item) }
                            .disabled(item.missing)
                        Divider()
                        Button("Aus der Ablage entfernen") {
                            withAnimation(.snappy(duration: 0.2)) { shelf.remove(item) }
                        }
                    }
            }
        }
    }
}

/// Ein Eintrag: Vorschaubild und Name, per Ziehen wieder herauszuholen.
private struct ShelfItemView: View {
    let item: ShelfItem
    let thumbSize: CGFloat
    let width: CGFloat

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 3) {
            thumbnail
                .frame(width: thumbSize, height: thumbSize)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7))
                .overlay {
                    if item.missing {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(.orange.opacity(0.7), lineWidth: 1)
                    }
                }
            Text(item.name)
                .font(.system(size: 9))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(item.missing ? .orange : .secondary)
                .frame(width: width)
        }
        .opacity(item.missing ? 0.6 : 1)
        .help(item.missing ? "\(item.name) — nicht mehr auffindbar" : item.url.path)
        .onTapGesture(count: 2) {
            guard !item.missing else { return }
            FileShelf.shared.open(item)
        }
        // NSItemProvider(contentsOf:) liefert eine echte Datei-Referenz —
        // damit landet die Datei beim Ziehen im Finder bzw. der Zielapp.
        .onDrag {
            guard !item.missing, let provider = NSItemProvider(contentsOf: item.url) else {
                return NSItemProvider()
            }
            provider.suggestedName = item.name
            return provider
        } preview: {
            thumbnail.frame(width: thumbSize, height: thumbSize)
        }
        .task(id: item.url) {
            if let hit = ThumbnailCache.shared.cached(item.url, size: thumbSize) {
                image = hit
            } else {
                image = await ThumbnailCache.shared.thumbnail(for: item.url, size: thumbSize)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(2)
        } else {
            Image(systemName: item.isDirectory ? "folder" : "doc")
                .font(.system(size: thumbSize * 0.4, weight: .light))
                .foregroundStyle(.secondary)
        }
    }
}
