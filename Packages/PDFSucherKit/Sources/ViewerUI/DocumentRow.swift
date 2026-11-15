// DocumentRow.swift — Task 4.3
import OutputKit
import SearchKit
import SwiftUI

/// "<Dateiname> (<n> Treffer)" above a horizontally scrolling, lazy row of hit pages.
struct DocumentRow: View {
    /// Header line height for a font size (spec 1.1 §1): 1.5 × the size, 24 pt at the default 16 pt.
    static func headerHeight(fontSize: Int) -> CGFloat { (CGFloat(fontSize) * 1.5).rounded(.up) }
    static let scrollerAllowance: CGFloat = 12
    /// Height a row needs besides its tiles: header, gap, horizontal scroller. Tick and page number sit
    /// on the tile (Chris, Task 5.6), so there is no caption line.
    static func overhead(fontSize: Int) -> CGFloat { headerHeight(fontSize: fontSize) + 4 + scrollerAllowance }

    let hit: DocumentHit
    /// The A4 portrait tile of the grid; this row fits its document's page shape into it (1.3.4).
    let baseTileSize: CGSize
    let shapes: PageShapes
    let model: any ViewerModel
    let cache: ThumbnailCache
    let folderUnreachable: Bool
    let highlightKey: String
    let highlightRanges: HighlightRanges?
    /// A tile at this position came into view (spec 1.2.4 §2: the grid prefetches the area once).
    var onTileAppear: ((Int) -> Void)?
    let onFocusTile: (PageRef) -> Void
    /// Bumped when the page shape lookup finished, so the row redraws in its shape (`PageShapes` is not observed).
    @State private var shapeLookups = 0

    var body: some View {
        // Read for Word/PowerPoint rows only (as for the tiles): PDF and image rows must not redraw on layout progress.
        let shapeRevision = hit.kind.isOffice ? model.layoutRevision : 0
        let shapeReady = shapeLookups >= 0 && shapes.isResolved(hit.url, revision: shapeRevision)
        let tileSize = shapes.tileSize(for: hit, base: baseTileSize)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let symbol = ViewerText.rowSymbol(hit) {
                    Image(systemName: symbol).foregroundStyle(.secondary).accessibilityLabel(ViewerText.kindLabel(hit.kind))
                }
                Text(Self.headerText(hit, ranges: highlightRanges, color: model.settings.highlightColor))
                    .font(.system(size: CGFloat(model.settings.headerFontSize), weight: .bold))
                    .layoutPriority(1)       // the folder label gives way first
                if Self.showsNameHint(hit) {
                    Text(ViewerText.nameHit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
                        .help(ViewerText.nameHitHelp)
                        .layoutPriority(1)
                        .accessibilityHint(ViewerText.nameHitHelp)
                        .accessibilityIdentifier("nameHitHint")
                }
                if Self.showsSimplifiedHint(hit) {
                    Text(ViewerText.simplified)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
                        .help(ViewerText.simplifiedHelp)
                        .layoutPriority(1)
                        .accessibilityHint(ViewerText.simplifiedHelp)
                        .accessibilityIdentifier("simplifiedHint")
                }
                let folder = ViewerText.rowFolder(hit, showSource: model.sources.count > 1)
                if !folder.isEmpty {
                    Text(folder).font(.callout).foregroundStyle(.secondary).truncationMode(.head)
                }
            }
            .lineLimit(1)
            .frame(height: Self.headerHeight(fontSize: model.settings.headerFontSize), alignment: .leading)
            .help(hit.relativePath)

            let showAll = model.settings.showAllPages
            if hit.isUnreadable || RowPages.count(for: hit, showAll: showAll) == 0 {
                Label(ViewerText.rowHint(hit), systemImage: hit.isUnreadable ? "exclamationmark.triangle" : "hourglass")
                    .foregroundStyle(.secondary)
                    .frame(height: tileSize.height + 4 + Self.scrollerAllowance, alignment: .topLeading)
                    .accessibilityIdentifier("rowHint")
            } else if !shapeReady {
                // The page shape is looked up first (one page header read): tiles are rendered once, in their shape.
                Color.clear
                    .frame(width: tileSize.width, height: tileSize.height + 4 + Self.scrollerAllowance)
                    .accessibilityHidden(true)
            } else {
            ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 8) {
                    let pages = RowPages.pages(for: hit, showAll: showAll)
                    ForEach(Array(pages.enumerated()), id: \.element.pageIndex) { position, page in
                        let ref = PageRef(url: hit.url, pageIndex: page.pageIndex)
                        let style = TileStyle.make(matchCount: page.matchCount, showAll: showAll, isSearchHit: !hit.pageHits.isEmpty)
                        ThumbnailTile(
                            ref: ref,
                            kind: hit.kind,
                            size: tileSize,
                            isSelected: model.selection.contains(ref),
                            isFocused: model.focusedPage == ref,
                            folderUnreachable: folderUnreachable,
                            cache: cache,
                            highlightKey: highlightKey,
                            highlightRanges: style.highlights ? highlightRanges : nil,
                            style: style,
                            highlightColor: model.settings.highlightColor,
                            ocrText: { await model.ocrText(for: $0) },
                            // Read for Word/PowerPoint rows only: PDF and image rows must not redraw on layout progress.
                            layoutRevision: hit.kind.isOffice ? model.layoutRevision : 0,
                            pagesRevision: hit.kind.isOffice ? model.foreignPagesRevision : 0,
                            documentPageCount: hit.pageCount,
                            onSlidesMissing: { model.slidesMissing(for: ref) },
                            onToggle: { model.selection.toggle(ref) },
                            onFocus: { onFocusTile(ref) },
                            onOpen: { model.openInPreview(ref) }
                        )
                        .id(FocusNavigator.tileID(ref))
                        .onAppear { onTileAppear?(position) }
                    }
                }
            }
            .scrollIndicators(.automatic)
            .contentMargins(.bottom, Self.scrollerAllowance, for: .scrollContent)   // legacy scrollers must not cover the tiles
            .frame(height: tileSize.height + 4 + Self.scrollerAllowance)
            .onChange(of: model.focusedPage) { _, focused in
                guard let focused, focused.url == hit.url else { return }
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(FocusNavigator.tileID(focused)) }
            }
            .onAppear {
                // Row built lazily after the focus moved here (arrow down/up, ‹ ›).
                if let focused = model.focusedPage, focused.url == hit.url {
                    proxy.scrollTo(FocusNavigator.tileID(focused))
                } else if showAll {
                    scrollToFirstHit(proxy)
                }
            }
            .onChange(of: showAll) { _, on in
                // §8: switching „Alle Seiten“ on scrolls each row to its first hit page.
                if on { scrollToFirstHit(proxy) }
            }
            }
            }
        }
        .task(id: ShapeLookup(url: hit.url, revision: shapeRevision)) {
            guard !shapes.isResolved(hit.url, revision: shapeRevision) else { return }
            await shapes.resolve(hit, revision: shapeRevision, cache: cache)
            shapeLookups += 1
        }
        // A Word document or deck in view: the app may start Office's font registration (1.3.2).
        .onAppear { if hit.kind.isOffice { model.officeDocumentShown(hit.url) } }
        // The whole row (header and tiles), so UI tests find a row's checkboxes inside it.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ViewerText.rowHeader(hit))
        .accessibilityIdentifier("documentRow")
    }

    private func scrollToFirstHit(_ proxy: ScrollViewProxy) {
        guard let first = hit.pageHits.first else { return }
        proxy.scrollTo(FocusNavigator.tileID(PageRef(url: hit.url, pageIndex: first.pageIndex)), anchor: .leading)
    }
}

extension DocumentRow {
    struct ShapeLookup: Equatable { let url: URL; let revision: Int }

    /// „vereinfacht“ next to the header: documents drawn by TextKit (renderer `textkit`, today every Word file).
    static func showsSimplifiedHint(_ hit: DocumentHit) -> Bool { hit.isSimplified }

    /// „Treffer im Dateinamen“ for a document found by its name only (spec 1.3.2 §2).
    static func showsNameHint(_ hit: DocumentHit) -> Bool { hit.nameMatch && hit.pageHits.isEmpty }

    /// The row header with the query highlighted in the file name (without extension; never in the counts) when the
    /// name matched (spec 1.3.2 §2), in the highlight colour of the settings.
    static func headerText(_ hit: DocumentHit, ranges: HighlightRanges?, color: RGBA) -> AttributedString {
        let header = ViewerText.rowHeader(hit)
        let base = DocumentHit.searchableName(of: hit.url.lastPathComponent)
        guard hit.nameMatch, let ranges, !base.isEmpty, header.hasPrefix(base) else { return AttributedString(header) }
        let background = Color(.sRGB, red: color.r, green: color.g, blue: color.b, opacity: max(color.a, 0.6))
        var text = AttributedString()
        var cursor = base.startIndex
        for range in ranges(base).sorted(by: { $0.lowerBound < $1.lowerBound }) where range.lowerBound >= cursor {
            text += AttributedString(String(base[cursor..<range.lowerBound]))
            var marked = AttributedString(String(base[range]))
            marked.backgroundColor = background
            text += marked
            cursor = range.upperBound
        }
        text += AttributedString(String(base[cursor...]))
        text += AttributedString(String(header.dropFirst(base.count)))
        return text
    }

    /// First tile of a row when it comes into view: its first hit with „Alle Seiten“, else the start.
    static func firstShownPosition(_ hit: DocumentHit, showAll: Bool) -> Int {
        guard showAll else { return 0 }
        return RowPages.firstHitIndex(in: RowPages.pages(for: hit, showAll: true)) ?? 0
    }
}
