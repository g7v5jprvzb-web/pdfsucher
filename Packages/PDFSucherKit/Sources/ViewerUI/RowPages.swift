// RowPages.swift — 1.1 Task 4 (spec 1.1 §12 browsing; §8 „Alle Seiten“ extends it)
import CoreGraphics
import Foundation
import SearchKit

/// One tile of a document row: a page and its number of matches (0 = no hit, or browsing).
public struct RowPage: Hashable, Sendable {
    public let pageIndex: Int
    public let matchCount: Int

    public init(pageIndex: Int, matchCount: Int) {
        self.pageIndex = pageIndex
        self.matchCount = matchCount
    }
}

/// Which pages a document row shows.
/// - A browse entry (no search term: no page hits) shows all its pages.
/// - A search hit shows its hit pages; with `showAll` (§8) all pages, hit pages carrying their count.
/// - An unreadable file shows none.
public enum RowPages {
    public static func pages(for hit: DocumentHit, showAll: Bool) -> [RowPage] {
        if hit.isUnreadable { return [] }
        if hit.pageHits.isEmpty { return (0..<max(hit.pageCount, 0)).map { RowPage(pageIndex: $0, matchCount: 0) } }
        guard showAll, coversAllHits(hit) else {
            return hit.pageHits.map { RowPage(pageIndex: $0.pageIndex, matchCount: $0.matchCount) }
        }
        var counts = [Int](repeating: 0, count: hit.pageCount)
        for page in hit.pageHits where counts.indices.contains(page.pageIndex) { counts[page.pageIndex] = page.matchCount }
        return counts.enumerated().map { RowPage(pageIndex: $0.offset, matchCount: $0.element) }
    }

    /// Number of tiles, without building them.
    static func count(for hit: DocumentHit, showAll: Bool) -> Int {
        if hit.isUnreadable { return 0 }
        if hit.pageHits.isEmpty { return max(hit.pageCount, 0) }
        return showAll && coversAllHits(hit) ? hit.pageCount : hit.pageHits.count
    }

    /// Page index of the tile at `position`.
    static func pageIndex(of hit: DocumentHit, at position: Int, showAll: Bool) -> Int {
        if hit.pageHits.isEmpty || (showAll && coversAllHits(hit)) { return position }
        return hit.pageHits[position].pageIndex
    }

    /// Position of `pageIndex` among the tiles, or nil.
    static func position(of pageIndex: Int, in hit: DocumentHit, showAll: Bool) -> Int? {
        let count = count(for: hit, showAll: showAll)
        if hit.pageHits.isEmpty || (showAll && coversAllHits(hit)) {
            return pageIndex >= 0 && pageIndex < count ? pageIndex : nil
        }
        return hit.pageHits.firstIndex { $0.pageIndex == pageIndex }
    }

    /// The first tile with matches (scroll target when „Alle Seiten“ is switched on).
    public static func firstHitIndex(in pages: [RowPage]) -> Int? {
        pages.firstIndex { $0.matchCount > 0 }
    }

    /// The page count is known and contains every hit page (otherwise only hit pages are shown).
    private static func coversAllHits(_ hit: DocumentHit) -> Bool {
        hit.pageCount > 0 && (hit.pageHits.map(\.pageIndex).max() ?? 0) < hit.pageCount
    }
}

/// How a tile looks (spec 1.1 §8): with „Alle Seiten“ hit pages get the accent frame, a badge with their
/// count and highlights; other pages are dimmed. Browsing and the switch off: no marking.
struct TileStyle: Equatable {
    static let dimmedOpacity = 0.7
    static let hitFrameWidth: CGFloat = 3

    let hitFrame: Bool
    let badge: Int?
    let dimmed: Bool
    let highlights: Bool

    static func make(matchCount: Int, showAll: Bool, isSearchHit: Bool) -> TileStyle {
        guard isSearchHit else { return TileStyle(hitFrame: false, badge: nil, dimmed: false, highlights: false) }
        guard showAll else { return TileStyle(hitFrame: false, badge: nil, dimmed: false, highlights: true) }
        return matchCount > 0
            ? TileStyle(hitFrame: true, badge: matchCount, dimmed: false, highlights: true)
            : TileStyle(hitFrame: false, badge: nil, dimmed: true, highlights: false)
    }
}
