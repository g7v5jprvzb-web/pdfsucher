// TilePrefetcher.swift — 1.2.4 §2: one cancellable prefetch for the visible area
import Foundation
import OutputKit
import SearchKit

/// Collects which rows and tiles are on screen and, once scrolling pauses (`delay`), asks the cache to
/// render ahead the area next to them in one batch: per visible row the tiles right of its last visible
/// one, and the first tiles of the two rows below. A new batch replaces the previous one (1.2.3 queued a
/// prefetch per appearing tile and row, never cancelled).
@MainActor final class TilePrefetcher {
    /// What the grid shows right now.
    struct Context {
        var cache: ThumbnailCache
        var hits: [DocumentHit]
        var columns: Int
        /// The tile size of a row (its page shape, 1.3.4); nil = not known yet, its tiles are left out.
        var tileSize: @MainActor (DocumentHit) -> CGSize?
        var showAll: Bool
        var highlightKey: String
        var highlightRanges: HighlightRanges?
        var color: RGBA
        var ocr: (@Sendable (PageRef) async -> OCRPageText?)?
    }

    static let rowsBelow = 2
    var delay: Duration = .milliseconds(80)
    /// During a long continuous scroll a batch goes out at least this often (review M2).
    var maxWait: Duration = .milliseconds(250)
    private var waitingSince: ContinuousClock.Instant?
    private(set) var visibleRows: Set<DocumentHit.ID> = []
    private(set) var lastTile: [DocumentHit.ID: Int] = [:]
    private var context: Context?
    private var flushTask: Task<Void, Never>?
    /// Batches sent (tests).
    private(set) var batches = 0

    init() {}

    func rowAppeared(_ id: DocumentHit.ID, _ context: Context) {
        visibleRows.insert(id)
        schedule(context)
    }

    func rowDisappeared(_ id: DocumentHit.ID, _ context: Context) {
        visibleRows.remove(id)
        lastTile[id] = nil
        schedule(context)
    }

    func tileAppeared(_ id: DocumentHit.ID, position: Int, _ context: Context) {
        lastTile[id] = max(lastTile[id] ?? position, position)
        schedule(context)
    }

    private func schedule(_ context: Context) {
        self.context = context
        flushTask?.cancel()
        let now = ContinuousClock.now
        if let since = waitingSince, now - since >= maxWait {
            flush()
            return
        }
        if waitingSince == nil { waitingSince = now }
        let delay = delay
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Sends the batch for the current area now.
    func flush() {
        waitingSince = nil
        guard let context else { return }
        let planned = Self.plan(hits: context.hits, visible: visibleRows, lastTile: lastTile, columns: context.columns,
                                showAll: context.showAll, highlighted: context.highlightRanges != nil)
        batches += 1
        let sizes = Self.sizes(of: planned.plain + planned.marked, hits: context.hits, tileSize: context.tileSize)
        var groups: [ThumbnailCache.PrefetchGroup] = []
        for (size, refs) in Self.grouped(planned.plain, sizes: sizes) {
            groups.append(ThumbnailCache.PrefetchGroup(refs: refs, size: size))
        }
        for (size, refs) in Self.grouped(planned.marked, sizes: sizes) {
            groups.append(ThumbnailCache.PrefetchGroup(refs: refs, size: size, highlightKey: context.highlightKey,
                                                       highlightRanges: context.highlightRanges, highlightColor: context.color,
                                                       ocr: context.ocr))
        }
        context.cache.prefetch(groups)
    }

    /// Tile size per file of the planned tiles (asked once per file).
    private static func sizes(of refs: [PageRef], hits: [DocumentHit], tileSize: (DocumentHit) -> CGSize?) -> [URL: CGSize] {
        let wanted = Set(refs.map(\.url))
        var sizes: [URL: CGSize] = [:]
        for hit in hits where wanted.contains(hit.url) && sizes[hit.url] == nil {
            if let size = tileSize(hit) { sizes[hit.url] = size }
        }
        return sizes
    }

    /// The tiles split by size, in order of first appearance; tiles without a size are left out (pure).
    static func grouped(_ refs: [PageRef], sizes: [URL: CGSize]) -> [(CGSize, [PageRef])] {
        var groups: [(CGSize, [PageRef])] = []
        for ref in refs {
            guard let size = sizes[ref.url] else { continue }
            if let i = groups.firstIndex(where: { $0.0 == size }) { groups[i].1.append(ref) } else { groups.append((size, [ref])) }
        }
        return groups
    }

    /// The tiles to render ahead (pure): for each visible row the `columns` tiles after its last visible
    /// one (a row without tile reports: the screen width after its first one), then the first `columns`
    /// tiles of the `rowsBelow` rows under the lowest visible row. Marked = with highlights.
    static func plan(hits: [DocumentHit], visible: Set<DocumentHit.ID>, lastTile: [DocumentHit.ID: Int], columns: Int,
                     showAll: Bool, highlighted: Bool) -> (plain: [PageRef], marked: [PageRef]) {
        let columns = max(columns, 1)
        var plain: [PageRef] = [], marked: [PageRef] = []
        func add(_ hit: DocumentHit, _ positions: Range<Int>) {
            let pages = RowPages.pages(for: hit, showAll: showAll)
            let range = positions.clamped(to: pages.indices)
            for page in pages[range] {
                let ref = PageRef(url: hit.url, pageIndex: page.pageIndex)
                let style = TileStyle.make(matchCount: page.matchCount, showAll: showAll, isSearchHit: !hit.pageHits.isEmpty)
                if style.highlights, highlighted { marked.append(ref) } else { plain.append(ref) }
            }
        }
        let indices = hits.indices.filter { visible.contains(hits[$0].id) }
        for i in indices {
            let hit = hits[i]
            let first = DocumentRow.firstShownPosition(hit, showAll: showAll)
            let start = lastTile[hit.id].map { $0 + 1 } ?? first + columns
            add(hit, start..<(start + columns))
        }
        if let lowest = indices.last {
            for hit in hits.dropFirst(lowest + 1).prefix(rowsBelow) {
                let first = DocumentRow.firstShownPosition(hit, showAll: showAll)
                add(hit, first..<(first + columns))
            }
        }
        return (plain, marked)
    }
}
