import Testing
import Foundation
import OutputKit

@Suite("PageSelection")
struct PageSelectionTests {
    let a = URL(fileURLWithPath: "/docs/A.pdf")
    let b = URL(fileURLWithPath: "/docs/B.pdf")
    let c = URL(fileURLWithPath: "/docs/sub/C.pdf")
    let z = URL(fileURLWithPath: "/docs/Z.pdf")

    @Test func startsEmpty() {
        let s = PageSelection()
        #expect(s.count == 0)
        #expect(!s.contains(PageRef(url: a, pageIndex: 0)))
    }

    @Test func toggleAddsAndRemoves() {
        var s = PageSelection()
        let r = PageRef(url: a, pageIndex: 3)
        s.toggle(r)
        #expect(s.contains(r))
        #expect(s.count == 1)
        #expect(!s.contains(PageRef(url: a, pageIndex: 2)))
        s.toggle(r)
        #expect(!s.contains(r))
        #expect(s.count == 0)
    }

    @Test func clearRemovesEverything() {
        var s = PageSelection()
        s.toggle(PageRef(url: a, pageIndex: 0))
        s.toggle(PageRef(url: b, pageIndex: 1))
        s.clear()
        #expect(s.count == 0)
        #expect(s == PageSelection())
    }

    @Test func orderFollowsGrid() {
        var s = PageSelection()
        for r in [PageRef(url: b, pageIndex: 5), PageRef(url: a, pageIndex: 2),
                  PageRef(url: b, pageIndex: 1), PageRef(url: a, pageIndex: 0)] { s.toggle(r) }
        #expect(s.ordered(documentOrder: [b, a]) == [
            PageRef(url: b, pageIndex: 1), PageRef(url: b, pageIndex: 5),
            PageRef(url: a, pageIndex: 0), PageRef(url: a, pageIndex: 2),
        ])
    }

    @Test func unknownDocumentsGoLastSortedByPath() {
        // Selection survives a new search, so selected docs may be missing from the grid.
        var s = PageSelection()
        for r in [PageRef(url: z, pageIndex: 0), PageRef(url: a, pageIndex: 4),
                  PageRef(url: c, pageIndex: 1), PageRef(url: b, pageIndex: 2)] { s.toggle(r) }
        #expect(s.ordered(documentOrder: [b]) == [
            PageRef(url: b, pageIndex: 2),
            PageRef(url: a, pageIndex: 4), // /docs/A.pdf
            PageRef(url: c, pageIndex: 1), // /docs/sub/C.pdf
            PageRef(url: z, pageIndex: 0), // /docs/Z.pdf
        ])
    }

    @Test func unknownDocumentsSortLikeFinder() {
        var s = PageSelection()
        for name in ["10.pdf", "Z.pdf", "b.pdf", "2.pdf"] {
            s.toggle(PageRef(url: URL(fileURLWithPath: "/docs/" + name), pageIndex: 0))
        }
        #expect(s.ordered(documentOrder: []).map(\.url.lastPathComponent) == ["2.pdf", "10.pdf", "b.pdf", "Z.pdf"])
    }

    @Test func equalSpellingsStillOrderPagesAscending() {
        // Unequal URLs with identical path and absoluteString must not make the sort inconsistent.
        let relative = URL(fileURLWithPath: "A.pdf", relativeTo: URL(fileURLWithPath: "/docs/", isDirectory: true))
        try? #require(relative != a)
        var s = PageSelection()
        for r in [PageRef(url: relative, pageIndex: 2), PageRef(url: a, pageIndex: 1), PageRef(url: relative, pageIndex: 0)] { s.toggle(r) }
        #expect(s.ordered(documentOrder: []).map(\.pageIndex) == [0, 1, 2])
    }

    @Test func orderedIgnoresUnselectedAndDuplicateGridEntries() {
        var s = PageSelection()
        s.toggle(PageRef(url: a, pageIndex: 1))
        #expect(s.ordered(documentOrder: [b, a, a]) == [PageRef(url: a, pageIndex: 1)])
        #expect(PageSelection().ordered(documentOrder: [a, b]).isEmpty)
    }
}
