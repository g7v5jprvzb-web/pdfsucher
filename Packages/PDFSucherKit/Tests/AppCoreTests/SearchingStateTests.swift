import Foundation
import Testing
import ViewerUI
@testable import AppCore

/// Spec §4.2: while a (slow) search runs the app shows „Suche läuft…“ (final review, Task 5.6).
@MainActor @Suite("Searching state", .serialized)
struct SearchingStateTests {
    let folder = URL(fileURLWithPath: "/docs")

    @Test func searchingWhileSearchRuns() async {
        let index = FakeIndex()
        index.hits = [doc("a.pdf", pages: [0])]
        let model = makeModel(index: index)
        await model.open(folder: folder)
        #expect(!model.isSearching)
        index.holdSearches = true
        model.queryText = "Vertrag"
        #expect(await eventually { model.isSearching })
        index.holdSearches = false
        await model.waitUntilIdle()
        #expect(!model.isSearching)
        #expect(model.hits.count == 1)
    }

    @Test func clearingTheQueryEndsSearching() async {
        let index = FakeIndex()
        let model = makeModel(index: index)
        await model.open(folder: folder)
        index.holdSearches = true
        model.queryText = "Vertrag"
        #expect(await eventually { model.isSearching })
        model.queryText = ""
        #expect(!model.isSearching)
        index.holdSearches = false
        await model.waitUntilIdle()
        #expect(!model.isSearching)
    }

    @Test func failedSearchEndsSearching() async {
        let index = FakeIndex()
        let model = makeModel(index: index)
        await model.open(folder: folder)
        await model.waitUntilIdle()           // a finishing index run clears notices
        index.failNextSearch(with: CocoaError(.fileReadUnknown))
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        #expect(!model.isSearching)
        #expect(model.notice != nil)
    }

    @Test func statusText() {
        #expect(ViewerText.searching == "Suche läuft…")
    }
}
