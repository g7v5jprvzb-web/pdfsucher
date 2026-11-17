import SearchKit
import SwiftUI

/// Hit tiles grouped by file; the file cards wrap, so small tiles show more files side by side.
struct ResultsView: View {
    @Environment(AppModel.self) private var model
    @Binding var tileSize: Double
    @Binding var showFolders: Bool

    /// Tiles per file are capped so a long document does not fill the screen.
    static let maxTilesPerFile = 48

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("resultsSummary")
                Spacer()
                Image(systemName: "square.grid.3x3").font(.caption).foregroundStyle(.secondary)
                Slider(value: $tileSize, in: SettingsKey.tileSizeRange, step: 4)
                    .frame(width: 160)
                    .accessibilityLabel("Kachelgröße")
                    .accessibilityIdentifier("tileSizeSlider")
                Image(systemName: "square.grid.2x2").font(.body).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if model.documentCount == 0 && !model.isIndexing {
                ContentUnavailableView {
                    Label("Noch keine Dateien im Index", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("Gib PDF Search einen Ordner frei oder lege PDFs und JPEGs in der Dateien-App unter „Auf meinem iPad › PDF Search“ ab.")
                } actions: {
                    Button("Ordner freigeben …") { showFolders = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.parsedQuery.isEmpty {
                placeholder("Suchbegriff eingeben", detail: "Durchsucht wird \(model.selectionTitle).", symbol: "magnifyingglass")
            } else if model.hits.isEmpty && !model.isSearching {
                placeholder("Keine Treffer", detail: "in \(model.selectionTitle)", symbol: "doc.text.magnifyingglass")
            } else {
                ScrollView {
                    FlowLayout(spacing: 10) {
                        ForEach(model.hits) { hit in
                            FileCard(hit: hit, tileSize: tileSize)
                        }
                    }
                    .padding(12)
                }
                .accessibilityIdentifier("resultsScroll")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("resultsPane")
    }

    private var summary: String {
        guard !model.parsedQuery.isEmpty else { return model.selectionTitle }
        let pages = model.hits.reduce(0) { $0 + $1.pageHits.count }
        return "\(model.hits.count) Dateien · \(pages) Seiten · \(model.selectionTitle)"
    }

    private func placeholder(_ title: String, detail: String, symbol: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FileCard: View {
    @Environment(AppModel.self) private var model
    let hit: DocumentHit
    let tileSize: Double

    private var pages: [Int] { Array(hit.tilePages.prefix(ResultsView.maxTilesPerFile)) }
    private var columns: Int { min(pages.count, tileSize < 60 ? 6 : 4) }
    private var width: CGFloat {
        let tiles = CGFloat(columns) * (tileSize + 4) - 4
        return max(tiles, 150) + 16
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(hit.kind == .image ? "JPEG" : "PDF")
                    .font(.caption2.bold())
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(hit.kind == .image ? Color.orange.opacity(0.25) : Color.red.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                Spacer(minLength: 2)
                Text("\(hit.totalMatches)")
                    .font(.caption2.monospacedDigit().bold())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.2), in: Capsule())
                    .accessibilityLabel("\(hit.totalMatches) Treffer")
            }
            Text(hit.displayName)
                .font(.caption.weight(.semibold))
                .lineLimit(2).truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 4) {
                ForEach(pages, id: \.self) { page in
                    PageTile(hit: hit, page: page, size: tileSize,
                             count: hit.pageHits.first { $0.pageIndex == page }?.matchCount ?? 0,
                             isSelected: model.preview?.hit.id == hit.id && model.preview?.page == page)
                        .onTapGesture { model.show(hit, page: page) }
                }
                if hit.tilePages.count > pages.count {
                    Text("+\(hit.tilePages.count - pages.count)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: tileSize, height: tileSize * 1.3)
                }
            }
        }
        .padding(8)
        .frame(width: width, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if model.preview?.hit.id == hit.id {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
            }
        }
    }
}

private struct PageTile: View {
    let hit: DocumentHit
    let page: Int
    let size: Double
    let count: Int
    let isSelected: Bool
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Rectangle().fill(Color(.tertiarySystemFill))
                }
            }
            .frame(width: size, height: size * 1.3)
            .background(Color(.systemBackground))
            if hit.kind != .image && size >= 56 {
                Text("S. \(page + 1)")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 3)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 3))
                    .padding(2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isSelected ? Color.accentColor : Color.black.opacity(0.12),
                                                                 lineWidth: isSelected ? 2.5 : 0.5))
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel("\(hit.displayName), Seite \(page + 1), \(count) Treffer")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("tile-\(hit.displayName)-\(page + 1)")
        .task(id: "\(hit.url.path)#\(page)#\(Int(size))") {
            let pixel = Int((size * 1.3 * scale).rounded(.up) / 64 + 1) * 64
            image = await Thumbnails.shared.image(url: hit.url, page: page, isImage: hit.kind == .image, pixel: pixel)
        }
    }
}

/// Wraps its children into rows (left to right, then down).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in row.items {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [(Int, CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
