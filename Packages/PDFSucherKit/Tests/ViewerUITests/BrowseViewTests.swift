import Foundation
import OutputKit
import SearchKit
import Testing
@testable import ViewerUI

/// Spec 1.1 §12: rows of the browse view.
@Suite("Browse view logic")
struct BrowseViewTests {
    private func entry(_ name: String, pages: Int, hits: [Int] = [], unreadable: Bool = false) -> DocumentHit {
        DocumentHit(url: URL(fileURLWithPath: "/d/\(name)"), relativePath: name, modifiedAt: .distantPast,
                    pageHits: hits.map { PageHit(pageIndex: $0, matchCount: 2) }, totalMatches: hits.count * 2,
                    relevance: 0, sourceRoot: URL(fileURLWithPath: "/d"), pageCount: pages, isUnreadable: unreadable)
    }

    @Test func browseSummaryText() {
        #expect(ViewerText.browseSummary(files: 1_234, pages: 25_310) == "1.234 Dateien, 25.310 Seiten")
        #expect(ViewerText.browseSummary(files: 1, pages: 1) == "1 Datei, 1 Seite")
    }

    @Test func rowHeaderShowsPagesWhileBrowsing() {
        #expect(ViewerText.rowHeader(entry("a.pdf", pages: 12)) == "a.pdf (12 Seiten)")
        #expect(ViewerText.rowHeader(entry("a.pdf", pages: 1)) == "a.pdf (1 Seite)")
        #expect(ViewerText.rowHeader(entry("a.pdf", pages: 0)) == "a.pdf")
        #expect(ViewerText.rowHeader(entry("a.pdf", pages: 0, unreadable: true)) == "a.pdf")
        #expect(ViewerText.rowHeader(entry("a.pdf", pages: 9, hits: [1, 3])) == "a.pdf (4 Treffer)")
        #expect(ViewerText.unreadableRow == "nicht lesbar")
    }

    @Test func rowPagesForBrowseAndSearch() {
        #expect(RowPages.pages(for: entry("a.pdf", pages: 3), showAll: false)
                == [RowPage(pageIndex: 0, matchCount: 0), RowPage(pageIndex: 1, matchCount: 0), RowPage(pageIndex: 2, matchCount: 0)])
        #expect(RowPages.pages(for: entry("a.pdf", pages: 9, hits: [1, 3]), showAll: false)
                == [RowPage(pageIndex: 1, matchCount: 2), RowPage(pageIndex: 3, matchCount: 2)])
        #expect(RowPages.pages(for: entry("a.pdf", pages: 5, unreadable: true), showAll: false).isEmpty)
    }

    @Test func navigatorWalksBrowseRows() {
        let hits = [entry("a.pdf", pages: 3), entry("b.pdf", pages: 2)]
        let a = hits[0].url, b = hits[1].url
        #expect(FocusNavigator.next(from: nil, direction: .right, hits: hits) == PageRef(url: a, pageIndex: 0))
        #expect(FocusNavigator.next(from: PageRef(url: a, pageIndex: 2), direction: .down, hits: hits) == PageRef(url: b, pageIndex: 1))
        #expect(FocusNavigator.contains(PageRef(url: a, pageIndex: 2), in: hits))
        #expect(FocusNavigator.step(from: PageRef(url: a, pageIndex: 2), by: 1, hits: hits) == PageRef(url: b, pageIndex: 0))
    }

    @Test func sortLabelShowsFallback() {
        #expect(ViewerText.sortLabel(.matchCount, browsing: true) == "Trefferanzahl (ohne Suche: nach Ordner)")
        #expect(ViewerText.sortLabel(.relevance, browsing: true) == "Relevanz (ohne Suche: nach Ordner)")
        #expect(ViewerText.sortLabel(.fileName, browsing: true) == "Dateiname")
        #expect(ViewerText.sortLabel(.matchCount, browsing: false) == "Trefferanzahl")
        #expect(ViewerText.browseSortMode(.matchCount) == .folder)
        #expect(ViewerText.browseSortMode(.relevance) == .folder)
        #expect(ViewerText.browseSortMode(.modifiedDate) == .modifiedDate)
    }

    // MARK: Review of Task 4

    @Test func stepSkipsRowsWithoutTilesAndStopsAtEnds() {
        let hits = [entry("a.pdf", pages: 2), entry("leer.pdf", pages: 5, unreadable: true), entry("b.pdf", pages: 1)]
        let a = hits[0].url, b = hits[2].url
        #expect(FocusNavigator.step(from: PageRef(url: a, pageIndex: 1), by: 1, hits: hits) == PageRef(url: b, pageIndex: 0))
        #expect(FocusNavigator.step(from: PageRef(url: b, pageIndex: 0), by: -1, hits: hits) == PageRef(url: a, pageIndex: 1))
        #expect(FocusNavigator.step(from: PageRef(url: b, pageIndex: 0), by: 1, hits: hits) == PageRef(url: b, pageIndex: 0))
        #expect(!FocusNavigator.canStep(from: PageRef(url: b, pageIndex: 0), by: 1, hits: hits))
        #expect(FocusNavigator.canStep(from: PageRef(url: b, pageIndex: 0), by: -1, hits: hits))
        #expect(FocusNavigator.step(from: nil, by: 1, hits: hits) == PageRef(url: a, pageIndex: 0))
    }

    @Test func stepIsFastWithTenThousandFiles() {
        let hits = (0..<10_000).map { entry("d\($0).pdf", pages: 20) }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            var ref = PageRef(url: hits[5_000].url, pageIndex: 19)
            for _ in 0..<200 {
                _ = FocusNavigator.canStep(from: ref, by: 1, hits: hits)
                ref = FocusNavigator.step(from: ref, by: 1, hits: hits) ?? ref
            }
        }
        #expect(elapsed < .milliseconds(500), "\(elapsed)")
    }

    @Test func showAllIgnoresOutOfRangeHitPages() {
        let odd = DocumentHit(url: URL(fileURLWithPath: "/d/x.pdf"), relativePath: "x.pdf", modifiedAt: .distantPast,
                              pageHits: [PageHit(pageIndex: 3, matchCount: 1), PageHit(pageIndex: 1, matchCount: 2), PageHit(pageIndex: -1, matchCount: 1)],
                              totalMatches: 4, relevance: 0, sourceRoot: URL(fileURLWithPath: "/d"), pageCount: 4)
        let pages = RowPages.pages(for: odd, showAll: true)
        #expect(pages.count == 4)
        #expect(pages.map(\.matchCount) == [0, 2, 0, 1])
    }
}
