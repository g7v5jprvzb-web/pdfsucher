import Foundation
import OutputKit
import SearchKit
import Testing
import ViewerUI
@testable import AppCore

/// Spec 1.1 §5 (coordinator: first rows < 200 ms also for searches with very many hit pages): a slow
/// search shows the documents of its first batch early, then the final list once.
@MainActor @Suite("Early search results")
struct PartialResultsTests {
    let folder = URL(fileURLWithPath: "/docs")

    @Test func earlyRowsAppearThenTheFinalListOnce() async {
        let index = FakeIndex()
        index.partialHits = [doc("a.pdf", pages: [0], matches: 1)]
        index.hits = [doc("b.pdf", pages: [0, 1], matches: 9), doc("a.pdf", pages: [0], matches: 1)]
        index.holdSearches = true
        let model = makeModel(index: index)
        await model.open(folder: folder)
        await model.waitUntilIdle()
        model.queryText = "ver*"
        #expect(await eventually(.seconds(2)) { model.hits.map(\.relativePath) == ["a.pdf"] })
        #expect(model.isSearching)
        #expect(model.summary == "Gefunden in 1 Dokument, 1 Seite")
        let ref = PageRef(url: model.hits[0].url, pageIndex: 0)
        model.selection.toggle(ref)
        model.focusedPage = ref
        index.holdSearches = false
        await model.waitUntilIdle()
        #expect(model.hits.map(\.relativePath) == ["b.pdf", "a.pdf"])     // final, sorted by match count
        #expect(!model.isSearching)
        #expect(model.selection.contains(ref))
        #expect(model.focusedPage == ref)
    }

    @Test func fastSearchShowsNoEarlyList() async {
        let index = FakeIndex()
        index.partialHits = [doc("a.pdf", pages: [0])]
        index.hits = [doc("a.pdf", pages: [0]), doc("b.pdf", pages: [0])]
        let model = makeModel(index: index)
        await model.open(folder: folder)
        await model.waitUntilIdle()
        let published = HitLog()
        model.onHitsPublished = { published.append($0.map(\.relativePath)) }
        model.queryText = "ver*"
        await model.waitUntilIdle()
        #expect(published.entries == [["a.pdf", "b.pdf"]])
    }

    @Test func staleEarlyRowsAreNotShownAfterANewQuery() async {
        let index = FakeIndex()
        index.partialHits = [doc("alt.pdf", pages: [0])]
        index.holdSearches = true
        let model = makeModel(index: index)
        await model.open(folder: folder)
        await model.waitUntilIdle()
        model.queryText = "ver*"
        #expect(await eventually(.seconds(2)) { !model.hits.isEmpty })
        index.partialHits = nil
        index.hits = [doc("neu.pdf", pages: [0])]
        index.holdSearches = false
        model.queryText = "neu"
        await model.waitUntilIdle()
        #expect(model.hits.map(\.relativePath) == ["neu.pdf"])
    }
}

final class HitLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [[String]] = []
    var entries: [[String]] { lock.withLock { _entries } }
    func append(_ e: [String]) { lock.withLock { _entries.append(e) } }
}
