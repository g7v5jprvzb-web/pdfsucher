import Foundation
import OutputKit
import SearchKit
import Testing
@testable import ViewerUI

/// Spec 1.1 §8: „Alle Seiten“.
@MainActor @Suite("All pages")
struct AllPagesTests {
    private func hit(_ name: String, pages: Int, hits: [Int]) -> DocumentHit {
        DocumentHit(url: URL(fileURLWithPath: "/d/\(name)"), relativePath: name, modifiedAt: .distantPast,
                    pageHits: hits.map { PageHit(pageIndex: $0, matchCount: $0 + 1) }, totalMatches: hits.count,
                    relevance: 0, sourceRoot: URL(fileURLWithPath: "/d"), pageCount: pages)
    }

    @Test func settingDefaultsOffAndPersists() {
        let defaults = UserDefaults(suiteName: "All-\(UUID())")!
        let s = GridSettings(defaults: defaults)
        #expect(!s.showAllPages)
        s.showAllPages = true
        #expect(defaults.bool(forKey: "grid.showAllPages"))
        #expect(GridSettings(defaults: defaults).showAllPages)
    }

    @Test func rowPagesOffIsHitPages() {
        #expect(RowPages.pages(for: hit("a", pages: 5, hits: [1, 3]), showAll: false).map(\.pageIndex) == [1, 3])
    }

    @Test func rowPagesOnIsAllInOrderWithCounts() {
        let pages = RowPages.pages(for: hit("a", pages: 5, hits: [1, 3]), showAll: true)
        #expect(pages.map(\.pageIndex) == [0, 1, 2, 3, 4])
        #expect(pages.map(\.matchCount) == [0, 2, 0, 4, 0])
    }

    @Test func unknownPageCountFallsBack() {
        #expect(RowPages.pages(for: hit("a", pages: 0, hits: [1, 3]), showAll: true).map(\.pageIndex) == [1, 3])
        #expect(RowPages.pages(for: hit("a", pages: 2, hits: [1, 3]), showAll: true).map(\.pageIndex) == [1, 3])
    }

    @Test func firstHitIndexIsScrollTarget() {
        #expect(RowPages.firstHitIndex(in: RowPages.pages(for: hit("a", pages: 9, hits: [6, 8]), showAll: true)) == 6)
        #expect(RowPages.firstHitIndex(in: RowPages.pages(for: hit("a", pages: 3, hits: []), showAll: true)) == nil)
    }

    @Test func tileStyleMarksHitPages() {
        let hitPage = TileStyle.make(matchCount: 4, showAll: true, isSearchHit: true)
        #expect(hitPage == TileStyle(hitFrame: true, badge: 4, dimmed: false, highlights: true))
        let other = TileStyle.make(matchCount: 0, showAll: true, isSearchHit: true)
        #expect(other == TileStyle(hitFrame: false, badge: nil, dimmed: true, highlights: false))
        // Switch off, or browsing: no marking at all.
        #expect(TileStyle.make(matchCount: 4, showAll: false, isSearchHit: true) == TileStyle(hitFrame: false, badge: nil, dimmed: false, highlights: true))
        #expect(TileStyle.make(matchCount: 0, showAll: true, isSearchHit: false) == TileStyle(hitFrame: false, badge: nil, dimmed: false, highlights: false))
        #expect(TileStyle.dimmedOpacity == 0.7)
        #expect(TileStyle.hitFrameWidth == 3)
    }

    @Test func arrowKeysWalkAllPagesWhenOn() {
        let hits = [hit("a", pages: 4, hits: [2]), hit("b", pages: 3, hits: [0])]
        let a = hits[0].url, b = hits[1].url
        #expect(FocusNavigator.next(from: PageRef(url: a, pageIndex: 2), direction: .right, hits: hits, showAllPages: true)
                == PageRef(url: a, pageIndex: 3))
        #expect(FocusNavigator.next(from: PageRef(url: a, pageIndex: 3), direction: .down, hits: hits, showAllPages: true)
                == PageRef(url: b, pageIndex: 2))
        #expect(FocusNavigator.contains(PageRef(url: a, pageIndex: 0), in: hits, showAllPages: true))
        #expect(!FocusNavigator.contains(PageRef(url: a, pageIndex: 0), in: hits, showAllPages: false))
    }

    @Test func stepStaysOnHitPages() {
        let hits = [hit("a", pages: 4, hits: [2]), hit("b", pages: 3, hits: [0])]
        #expect(FocusNavigator.step(from: PageRef(url: hits[0].url, pageIndex: 2), by: 1, hits: hits) == PageRef(url: hits[1].url, pageIndex: 0))
        // From a non-hit page (ticked/focused in „Alle Seiten“) ‹ › start at the first hit page.
        #expect(FocusNavigator.step(from: PageRef(url: hits[0].url, pageIndex: 0), by: 1, hits: hits) == PageRef(url: hits[0].url, pageIndex: 2))
    }

    @Test(.timeLimit(.minutes(1))) func twoThousandPagesWithoutHang() {
        let big = hit("gross", pages: 2_000, hits: [3, 1_500, 1_999])
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let pages = RowPages.pages(for: big, showAll: true)
            #expect(pages.count == 2_000)
            var ref = PageRef(url: big.url, pageIndex: 0)
            for _ in 0..<500 { ref = FocusNavigator.next(from: ref, direction: .right, hits: [big], showAllPages: true) ?? ref }
            #expect(ref.pageIndex == 500)
        }
        #expect(elapsed < .milliseconds(200), "\(elapsed)")
    }

    // MARK: Review of Task 10

    @Test func stepFromNonHitPageStaysInItsDocument() {
        let hits = [hit("a", pages: 4, hits: [2]), hit("b", pages: 9, hits: [1, 6]), hit("c", pages: 3, hits: [0])]
        let b = hits[1].url
        #expect(FocusNavigator.step(from: PageRef(url: b, pageIndex: 3), by: 1, hits: hits) == PageRef(url: b, pageIndex: 6))
        #expect(FocusNavigator.step(from: PageRef(url: b, pageIndex: 3), by: -1, hits: hits) == PageRef(url: b, pageIndex: 1))
        #expect(FocusNavigator.step(from: PageRef(url: b, pageIndex: 8), by: 1, hits: hits) == PageRef(url: hits[2].url, pageIndex: 0))
        #expect(FocusNavigator.step(from: PageRef(url: b, pageIndex: 0), by: -1, hits: hits) == PageRef(url: hits[0].url, pageIndex: 2))
        #expect(FocusNavigator.canStep(from: PageRef(url: b, pageIndex: 3), by: 1, hits: hits))
        #expect(!FocusNavigator.canStep(from: PageRef(url: hits[2].url, pageIndex: 2), by: 1, hits: hits))
    }

    @Test func nearestShownAfterSwitchingOff() {
        let hits = [hit("a", pages: 9, hits: [1, 6])]
        let a = hits[0].url
        #expect(FocusNavigator.nearestShown(to: PageRef(url: a, pageIndex: 5), hits: hits, showAllPages: false) == PageRef(url: a, pageIndex: 6))
        #expect(FocusNavigator.nearestShown(to: PageRef(url: a, pageIndex: 2), hits: hits, showAllPages: false) == PageRef(url: a, pageIndex: 1))
        #expect(FocusNavigator.nearestShown(to: PageRef(url: a, pageIndex: 6), hits: hits, showAllPages: false) == PageRef(url: a, pageIndex: 6))
        #expect(FocusNavigator.nearestShown(to: PageRef(url: URL(fileURLWithPath: "/x"), pageIndex: 0), hits: hits, showAllPages: false) == nil)
    }
}
