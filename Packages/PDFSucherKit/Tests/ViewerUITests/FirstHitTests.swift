import Foundation
import OutputKit
import SearchKit
import Testing
@testable import ViewerUI

/// 1.3.3: the page a search shows in the large preview by itself.
@Suite("First hit page")
struct FirstHitTests {
    private func hit(_ name: String, pages: Int, hits: [Int], unreadable: Bool = false) -> DocumentHit {
        DocumentHit(url: URL(fileURLWithPath: "/d/\(name)"), relativePath: name, modifiedAt: .distantPast,
                    pageHits: hits.map { PageHit(pageIndex: $0, matchCount: 1) }, totalMatches: hits.count,
                    relevance: 0, sourceRoot: URL(fileURLWithPath: "/d"), pageCount: pages, isUnreadable: unreadable)
    }

    @Test func theFirstHitPageOfTheFirstDocument() {
        let hits = [hit("a", pages: 9, hits: [4, 2]), hit("b", pages: 3, hits: [0])]
        #expect(FocusNavigator.firstHit(in: hits) == PageRef(url: hits[0].url, pageIndex: 4), "grid order, not page order")
    }

    @Test func aNameOnlyHitShowsItsFirstPage() {
        let hits = [hit("a", pages: 3, hits: [])]
        #expect(FocusNavigator.firstHit(in: hits) == PageRef(url: hits[0].url, pageIndex: 0))
    }

    @Test func documentsWithoutTilesAreSkipped() {
        let hits = [hit("locked", pages: 0, hits: [], unreadable: true), hit("empty", pages: 0, hits: []),
                    hit("b", pages: 2, hits: [1])]
        #expect(FocusNavigator.firstHit(in: hits) == PageRef(url: hits[2].url, pageIndex: 1))
    }

    @Test func noTilesNoPage() {
        #expect(FocusNavigator.firstHit(in: []) == nil)
        #expect(FocusNavigator.firstHit(in: [hit("locked", pages: 2, hits: [], unreadable: true)]) == nil)
    }
}
