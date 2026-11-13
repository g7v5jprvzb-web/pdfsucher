// FocusNavigator.swift — Task 4.3; 1.1 Task 4 (rows from `RowPages`: browsing, „Alle Seiten“)
import Foundation
import OutputKit
import SearchKit

/// Pure keyboard/‹ › navigation over the result grid: one row per document, its tiles from `RowPages`.
public enum FocusNavigator {
    public enum Direction: Sendable { case left, right, up, down }

    /// Arrow-key move. Stays put at grid edges; up/down keep the tile's position in its row,
    /// clamped to the target row's length (rows without tiles are skipped). Unknown or nil focus
    /// starts at the first tile.
    public static func next(from current: PageRef?, direction: Direction, hits: [DocumentHit], showAllPages: Bool = false) -> PageRef? {
        let count = { (i: Int) in RowPages.count(for: hits[i], showAll: showAllPages) }
        guard let firstRow = hits.indices.first(where: { count($0) > 0 }) else { return nil }
        guard let current, let (row, column) = position(of: current, in: hits, showAll: showAllPages) else {
            return ref(hits[firstRow], 0, showAllPages)
        }
        switch direction {
        case .left: return ref(hits[row], max(column - 1, 0), showAllPages)
        case .right: return ref(hits[row], min(column + 1, count(row) - 1), showAllPages)
        case .up, .down:
            let candidates = direction == .up ? Array(hits.indices[..<row].reversed()) : Array(hits.indices[(row + 1)...])
            guard let target = candidates.first(where: { count($0) > 0 }) else { return current }
            return ref(hits[target], min(column, count(target) - 1), showAllPages)
        }
    }

    /// Previous/next tile in reading order across documents (‹ › in the detail view): hit pages while
    /// searching (also with „Alle Seiten“), all pages while browsing. Stays at the ends.
    public static func step(from current: PageRef?, by offset: Int, hits: [DocumentHit]) -> PageRef? {
        guard let first = firstTile(hits) else { return nil }
        guard let current else { return first }
        var remaining = abs(offset)
        var row: Int, column: Int
        if let found = position(of: current, in: hits, showAll: false) {
            (row, column) = found
        } else if remaining > 0, let start = entry(from: current, forward: offset > 0, hits) {
            // A page without a hit („Alle Seiten“): the next hit page after (or before) it counts as one step.
            (row, column) = start
            remaining -= 1
        } else {
            return first
        }
        for _ in 0..<remaining {
            guard let next = neighbour(row, column, forward: offset > 0, hits) else { break }
            (row, column) = next
        }
        return ref(hits[row], column, false)
    }

    public static func canStep(from current: PageRef?, by offset: Int, hits: [DocumentHit]) -> Bool {
        guard let current else { return firstTile(hits) != nil }
        var remaining = abs(offset)
        var row: Int, column: Int
        if let found = position(of: current, in: hits, showAll: false) {
            (row, column) = found
        } else if hits.contains(where: { $0.url == current.url }) {
            guard remaining > 0, let start = entry(from: current, forward: offset > 0, hits) else { return false }
            (row, column) = start
            remaining -= 1
        } else {
            return firstTile(hits) != nil
        }
        for _ in 0..<remaining {
            guard let next = neighbour(row, column, forward: offset > 0, hits) else { return false }
            (row, column) = next
        }
        return true
    }

    /// For a page that is not a ‹ › tile: the first tile after it (or the last before it), in its own
    /// document first, then in the following (preceding) documents.
    private static func entry(from page: PageRef, forward: Bool, _ hits: [DocumentHit]) -> (Int, Int)? {
        guard let row = hits.firstIndex(where: { $0.url == page.url }) else { return nil }
        let tiles = RowPages.pages(for: hits[row], showAll: false)
        if forward, let i = tiles.firstIndex(where: { $0.pageIndex > page.pageIndex }) { return (row, i) }
        if !forward, let i = tiles.lastIndex(where: { $0.pageIndex < page.pageIndex }) { return (row, i) }
        // Past the row's last (before its first) tile: on to the neighbouring documents.
        return neighbour(row, forward ? max(tiles.count - 1, 0) : 0, forward: forward, hits)
    }

    /// The shown tile closest to `page` in its document (after „Alle Seiten“ was switched off); `page` itself
    /// if it is shown; nil if its document is not in the grid or shows no tiles.
    public static func nearestShown(to page: PageRef, hits: [DocumentHit], showAllPages: Bool) -> PageRef? {
        if contains(page, in: hits, showAllPages: showAllPages) { return page }
        guard let hit = hits.first(where: { $0.url == page.url }) else { return nil }
        let tiles = RowPages.pages(for: hit, showAll: showAllPages)
        guard let nearest = tiles.min(by: { abs($0.pageIndex - page.pageIndex) < abs($1.pageIndex - page.pageIndex) }) else { return nil }
        return PageRef(url: hit.url, pageIndex: nearest.pageIndex)
    }

    private static func firstTile(_ hits: [DocumentHit]) -> PageRef? {
        hits.firstIndex { RowPages.count(for: $0, showAll: false) > 0 }.map { ref(hits[$0], 0, false) }
    }

    /// The tile before or after (row, column) in reading order, skipping rows without tiles.
    private static func neighbour(_ row: Int, _ column: Int, forward: Bool, _ hits: [DocumentHit]) -> (Int, Int)? {
        let count = RowPages.count(for: hits[row], showAll: false)
        if forward, column + 1 < count { return (row, column + 1) }
        if !forward, column > 0 { return (row, column - 1) }
        var r = row
        while true {
            r += forward ? 1 : -1
            guard hits.indices.contains(r) else { return nil }
            let n = RowPages.count(for: hits[r], showAll: false)
            if n > 0 { return (r, forward ? 0 : n - 1) }
        }
    }

    /// Whether `r` is one of the tiles currently shown.
    public static func contains(_ r: PageRef?, in hits: [DocumentHit], showAllPages: Bool = false) -> Bool {
        guard let r else { return false }
        return position(of: r, in: hits, showAll: showAllPages) != nil
    }

    /// Stable identifier of a tile for `ScrollViewReader`.
    static func tileID(_ r: PageRef) -> String { "\(r.url.absoluteString)#\(r.pageIndex)" }

    private static func position(of r: PageRef, in hits: [DocumentHit], showAll: Bool) -> (Int, Int)? {
        guard let row = hits.firstIndex(where: { $0.url == r.url }),
              let column = RowPages.position(of: r.pageIndex, in: hits[row], showAll: showAll) else { return nil }
        return (row, column)
    }

    private static func ref(_ hit: DocumentHit, _ column: Int, _ showAll: Bool) -> PageRef {
        PageRef(url: hit.url, pageIndex: RowPages.pageIndex(of: hit, at: column, showAll: showAll))
    }
}
