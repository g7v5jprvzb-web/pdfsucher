import AppKit
import Foundation
import Testing
@testable import ViewerUI

/// Chris (Task 5.4): pages per row either fixed (1…10) or automatic — the tile size follows from the
/// row height, and as many tiles as fit into the window width are shown.
@Suite("Columns mode")
@MainActor
struct ColumnsModeTests {
    private func withTempDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "PDFSucher.ColumnsModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    @Test func columnsModeDefaultsToFixed() {
        withTempDefaults { d in
            #expect(GridSettings(defaults: d).columnsMode == .fixed)
            d.set("bogus", forKey: "grid.columnsMode")
            #expect(GridSettings(defaults: d).columnsMode == .fixed)
        }
    }

    @Test func columnsModePersists() {
        withTempDefaults { d in
            let a = GridSettings(defaults: d)
            a.columnsMode = .automatic
            #expect(d.string(forKey: "grid.columnsMode") == "automatic")
            #expect(GridSettings(defaults: d).columnsMode == .automatic)
        }
    }

    @Test func columnsThatFit() {
        #expect(GridLayout.columns(available: 1200, tileWidth: 100, spacing: 8) == 11)   // 11·100 + 10·8 = 1180
        #expect(GridLayout.columns(available: 1180, tileWidth: 100, spacing: 8) == 11)   // exactly fits
        #expect(GridLayout.columns(available: 1179, tileWidth: 100, spacing: 8) == 10)
    }

    @Test func automaticAtLeastOne() {
        #expect(GridLayout.columns(available: 50, tileWidth: 200, spacing: 8) == 1)
        #expect(GridLayout.columns(available: 0, tileWidth: 0, spacing: 8) == 1)
        #expect(GridLayout.columns(available: .nan, tileWidth: 100, spacing: 8) == 1)
        #expect(GridLayout.columns(available: 500, tileWidth: .infinity, spacing: 8) == 1)
    }

    @Test func automaticColumnsFitWidth() {
        let available = CGSize(width: 1200, height: 600)
        let metrics = GridLayout.metrics(available: available, rows: 3, columns: 5, mode: .automatic)
        let tileHeight = 600.0 / 3 - 24 - 8                 // row height minus header and spacing
        let tileWidth = tileHeight / GridLayout.pageAspect
        let expected = Int(((1200 + 8) / (tileWidth + 8)).rounded(.down))
        #expect(expected == 9)
        #expect(metrics.columns == expected)
        #expect(abs(metrics.tileSize.width - tileWidth) < 0.001)
        #expect(abs(metrics.tileSize.height - tileHeight) < 0.001)
    }

    @Test func automaticTilesFollowRowCount() {
        let available = CGSize(width: 1200, height: 600)
        let three = GridLayout.metrics(available: available, rows: 3, columns: 5, mode: .automatic)
        let six = GridLayout.metrics(available: available, rows: 6, columns: 5, mode: .automatic)
        #expect(six.tileSize.height < three.tileSize.height)
        #expect(six.columns > three.columns)
    }

    @Test func automaticTileNeverWiderThanWindow() {
        let metrics = GridLayout.metrics(available: CGSize(width: 100, height: 2000), rows: 1, columns: 5, mode: .automatic)
        #expect(metrics.columns == 1)
        #expect(metrics.tileSize.width <= 100)
        #expect(abs(metrics.tileSize.height / metrics.tileSize.width - GridLayout.pageAspect) < 0.01)
    }

    /// Final review (Task 5.6): with many rows on little height the tiles must never vanish, and the
    /// number of pages per row must not jump to absurd values; the row count becomes an upper bound.
    @Test func automaticTilesNeverBelowMinimum() {
        // Uncapped, to see the minimum itself.
        let m = GridLayout.metrics(available: CGSize(width: 1180, height: 400), rows: 6, columns: 5,
                                   mode: .automatic, rowHeader: 60, maxAutomaticColumns: nil)
        #expect(m.tileSize.width >= GridLayout.minTileWidth)
        #expect(abs(m.tileSize.height / m.tileSize.width - GridLayout.pageAspect) < 0.01)
        let fitting: CGFloat = (1180 + 8) / (GridLayout.minTileWidth + 8)
        #expect(m.columns == Int(fitting.rounded(.down)))
        let ten = GridLayout.metrics(available: CGSize(width: 1180, height: 700), rows: 10, columns: 5,
                                     mode: .automatic, rowHeader: 60)
        #expect(ten.tileSize.width >= GridLayout.minTileWidth)
        #expect(ten.columns <= 10)
    }

    @Test func minimumTileStillFitsNarrowWindow() {
        let m = GridLayout.metrics(available: CGSize(width: 50, height: 100), rows: 10, columns: 5, mode: .automatic)
        #expect(m.tileSize.width <= 50 && m.tileSize.width > 0)
        #expect(m.columns == 1)
    }

    /// Chris (Task 5.6): „Automatisch“ shows at most 10 pages per row; when more would fit, 10 tiles
    /// fill the width and grow accordingly (A4 ratio), the grid scrolls vertically.
    @Test func automaticShowsAtMostTenThatFillTheWidth() {
        #expect(GridLayout.maxAutomaticColumns == 10)
        let m = GridLayout.metrics(available: CGSize(width: 3000, height: 400), rows: 3, columns: 5, mode: .automatic)
        #expect(m.columns == 10)
        let width = (3000.0 - 9 * 8) / 10
        #expect(abs(m.tileSize.width - width) < 0.001)
        #expect(abs(m.tileSize.height - width * GridLayout.pageAspect) < 0.001)
        let uncapped = GridLayout.metrics(available: CGSize(width: 3000, height: 400), rows: 3, columns: 5,
                                          mode: .automatic, maxAutomaticColumns: nil)
        #expect(uncapped.columns > 10)
    }

    @Test func automaticBelowTenUnchanged() {
        // 1200×600, 3 rows: 9 fit (automaticColumnsFitWidth), the cap does not change anything.
        let capped = GridLayout.metrics(available: CGSize(width: 1200, height: 600), rows: 3, columns: 5, mode: .automatic)
        let uncapped = GridLayout.metrics(available: CGSize(width: 1200, height: 600), rows: 3, columns: 5,
                                          mode: .automatic, maxAutomaticColumns: nil)
        #expect(capped.columns == 9)
        #expect(capped.tileSize == uncapped.tileSize)
    }

    /// Chris (Task 5.4, option A): in fixed mode exactly n pages fill the width, the tile size follows
    /// from that, and the grid scrolls vertically; the row count does not matter.
    @Test func fixedColumnsFillWidth() {
        let available = CGSize(width: 1000, height: 600)
        let metrics = GridLayout.metrics(available: available, rows: 3, columns: 7, mode: .fixed)
        let width = (1000.0 - 6 * 8) / 7
        #expect(metrics.columns == 7)
        #expect(abs(metrics.tileSize.width - width) < 0.001)
        #expect(abs(metrics.tileSize.height - width * GridLayout.pageAspect) < 0.001)
    }

    @Test func fixedIgnoresRowsAndHeight() {
        let a = GridLayout.metrics(available: CGSize(width: 1200, height: 600), rows: 1, columns: 5, mode: .fixed)
        let b = GridLayout.metrics(available: CGSize(width: 1200, height: 300), rows: 10, columns: 5, mode: .fixed)
        #expect(a.tileSize == b.tileSize)
        #expect(a.tileSize.height > 300)            // taller than the window: the grid scrolls
    }

    @Test func fixedTileNeverNegativeOrNaN() {
        for (width, n) in [(0.0, 5), (10.0, 10), (.nan, 3), (500.0, 0)] {
            let m = GridLayout.metrics(available: CGSize(width: width, height: 600), rows: 3, columns: n, mode: .fixed)
            #expect(m.tileSize.width >= 0 && m.tileSize.height >= 0)
            #expect(!m.tileSize.width.isNaN && !m.tileSize.height.isNaN)
            #expect(m.columns >= 1)
        }
    }

    @Test func rowsApplyOnlyInAutomaticMode() {
        withTempDefaults { d in
            let s = GridSettings(defaults: d)
            s.columnsMode = .fixed
            #expect(!s.rowsApply)
            s.columnsMode = .automatic
            #expect(s.rowsApply)
        }
    }
}

/// Review of Task 5.4: tiles fill the width exactly, so an always-visible (legacy) vertical scroller must
/// be left out of the width, or the n-th tile is clipped.
@Suite("Grid content width")
@MainActor
struct GridContentWidthTests {
    @Test func legacyScrollerIsSubtracted() {
        let overlay = ResultGridView.contentSize(of: CGSize(width: 1000, height: 600), scrollerStyle: .overlay)
        let legacy = ResultGridView.contentSize(of: CGSize(width: 1000, height: 600), scrollerStyle: .legacy)
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        #expect(overlay.width == 1000 - 2 * ResultGridView.padding)
        #expect(legacy.width == overlay.width - scroller)
        #expect(legacy.height == 600 - 2 * ResultGridView.padding)
    }
}

/// Chris (Task 5.6): tick and page number sit on the tile (top left), so a row no longer reserves a
/// caption line under the tiles: header 24 + 4 + horizontal scroller 12 = 40 pt (was 60).
@Suite("Tile overlay")
@MainActor
struct TileOverlayTests {
    @Test func rowReservesNoCaption() {
        #expect(DocumentRow.overhead(fontSize: 16) == DocumentRow.headerHeight(fontSize: 16) + 4 + DocumentRow.scrollerAllowance)
        #expect(DocumentRow.overhead(fontSize: 16) == 40)    // 1.1 default header 16 pt keeps the 1.0 row height
    }

    @Test func automaticTilesUseTheFreedHeight() {
        let m = GridLayout.metrics(available: CGSize(width: 1200, height: 600), rows: 3, columns: 5,
                                   mode: .automatic, rowHeader: DocumentRow.overhead(fontSize: 16))
        #expect(abs(m.tileSize.height - (600.0 / 3 - 40 - 8)) < 0.001)
    }
}
