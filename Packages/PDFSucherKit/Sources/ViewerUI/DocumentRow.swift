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
    let tileSize: CGSize
    let model: any ViewerModel
    let cache: ThumbnailCache
    let folderUnreachable: Bool
    let highlightKey: String
    let highlightRanges: HighlightRanges?
    /// Tiles rendered ahead to the right of each tile that appears (spec 1.2.3): about one screen width.
    var prefetchAhead = 0
    let onFocusTile: (PageRef) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let symbol = ViewerText.rowSymbol(hit) {
                    Image(systemName: symbol).foregroundStyle(.secondary).accessibilityLabel(ViewerText.imageLabel)
                }
                Text(ViewerText.rowHeader(hit)).font(.system(size: CGFloat(model.settings.headerFontSize), weight: .bold))
                    .layoutPriority(1)       // the folder label gives way first
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
                Label(hit.isUnreadable ? ViewerText.unreadableRow : ViewerText.pagesPending,
                      systemImage: hit.isUnreadable ? "exclamationmark.triangle" : "hourglass")
                    .foregroundStyle(.secondary)
                    .frame(height: tileSize.height + 4 + Self.scrollerAllowance, alignment: .topLeading)
                    .accessibilityIdentifier("rowHint")
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
                            onToggle: { model.selection.toggle(ref) },
                            onFocus: { onFocusTile(ref) },
                            onOpen: { model.openInPreview(ref) }
                        )
                        .id(FocusNavigator.tileID(ref))
                        .onAppear {
                            guard prefetchAhead > 0 else { return }
                            Self.prefetch(hit, positions: (position + 1)..<(position + 1 + prefetchAhead), tileSize: tileSize,
                                          model: model, cache: cache, highlightKey: highlightKey, highlightRanges: highlightRanges)
                        }
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
    /// Renders the tiles at `positions` of a row ahead of time, with the marks they will show (spec 1.2.3).
    static func prefetch(_ hit: DocumentHit, positions: Range<Int>, tileSize: CGSize, model: any ViewerModel,
                         cache: ThumbnailCache, highlightKey: String, highlightRanges: HighlightRanges?) {
        let showAll = model.settings.showAllPages
        let pages = RowPages.pages(for: hit, showAll: showAll)
        let range = positions.clamped(to: pages.indices)
        guard !range.isEmpty else { return }
        var plain: [PageRef] = [], marked: [PageRef] = []
        for page in pages[range] {
            let ref = PageRef(url: hit.url, pageIndex: page.pageIndex)
            let style = TileStyle.make(matchCount: page.matchCount, showAll: showAll, isSearchHit: !hit.pageHits.isEmpty)
            if style.highlights, highlightRanges != nil { marked.append(ref) } else { plain.append(ref) }
        }
        let color = model.settings.highlightColor
        cache.prefetch(plain, size: tileSize)
        cache.prefetch(marked, size: tileSize, highlightKey: highlightKey, highlightRanges: highlightRanges,
                       highlightColor: color, ocr: { @MainActor ref in await model.ocrText(for: ref) })
    }

    /// First tile of a row when it comes into view: its first hit with „Alle Seiten“, else the start.
    static func firstShownPosition(_ hit: DocumentHit, showAll: Bool) -> Int {
        guard showAll else { return 0 }
        return RowPages.firstHitIndex(in: RowPages.pages(for: hit, showAll: true)) ?? 0
    }
}
