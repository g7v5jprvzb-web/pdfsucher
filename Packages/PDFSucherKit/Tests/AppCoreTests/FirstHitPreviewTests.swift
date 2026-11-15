import Foundation
import OutputKit
import SearchKit
import Testing
import ViewerUI
@testable import AppCore

/// 1.3.3: a search with hits shows its first hit page in the large preview at once (focused tile), without
/// an arrow key; the user's own choice is kept until the search term changes.
@MainActor @Suite("First hit in the preview", .timeLimit(.minutes(1)))
struct FirstHitPreviewTests {
    let folder = URL(fileURLWithPath: "/docs")

    /// The folder changed on disk: indexed again, then the same term is searched again (as after any update).
    let watcher = FakeWatcher()

    struct Excluding: DocumentFilter {
        let name: String
        func includes(_ hit: DocumentHit) -> Bool { hit.relativePath != name }
        var label: String { "ohne \(name)" }
    }

    func model(_ hits: [DocumentHit], settings: GridSettings? = nil) async -> (AppModel, FakeIndex) {
        let index = FakeIndex()
        index.hits = hits
        let m = makeModel(index: index, settings: settings)
        m.diskChangeCooldown = .zero
        m.folderWatcher = watcher
        await m.open(folder: folder)
        await m.waitUntilIdle()
        return (m, index)
    }

    func refresh(_ m: AppModel) async {
        watcher.fire([folder.path])
        await m.waitUntilIdle()
    }

    func page(_ name: String, _ index: Int) -> PageRef { PageRef(url: folder.appendingPathComponent(name), pageIndex: index) }

    @Test func aSearchWithHitsFocusesTheFirstHitPageOfTheFirstDocument() async {
        let (m, _) = await model([doc("b.pdf", pages: [4, 6], matches: 2), doc("a.pdf", pages: [3, 5], matches: 9)])
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.hits.map(\.relativePath) == ["a.pdf", "b.pdf"])     // sorted by match count
        #expect(m.focusedPage == page("a.pdf", 3))
    }

    @Test func theFirstHitFollowsTheShownOrderAndFilters() async {
        let settings = makeSettings()
        settings.sort = .fileName
        let (m, _) = await model([doc("b.pdf", pages: [1], matches: 9), doc("a.pdf", pages: [2], matches: 1)], settings: settings)
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.focusedPage == page("a.pdf", 2))
        m.extraFilters = [Excluding(name: "a.pdf")]
        await m.waitUntilIdle()
        #expect(m.focusedPage == page("b.pdf", 1), "a.pdf filtered out: b.pdf is the first shown document")
    }

    @Test func theAutomaticFocusDoesNotStoreTheTermInTheHistory() async throws {
        let (m, _) = await model([doc("a.pdf", pages: [0, 2])])
        m.historyDelay = .seconds(60)
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.focusedPage == page("a.pdf", 0))
        #expect(m.searchHistory.entries.isEmpty, "only the user's arrival (tile, arrow, tick, Return) stores it")
    }

    @Test func aNewTermFocusesItsFirstHitAgainAfterTheUserChose() async {
        let (m, index) = await model([doc("a.pdf", pages: [0, 2]), doc("b.pdf", pages: [1])])
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        m.focusedPage = page("b.pdf", 1)                       // click or arrow
        index.hits = [doc("a.pdf", pages: [2]), doc("b.pdf", pages: [1])]
        m.queryText = "Vertrag Miete"
        await m.waitUntilIdle()
        #expect(m.focusedPage == page("a.pdf", 2))
    }

    @Test func theUsersChoiceStaysWhenTheSameSearchShowsNewResults() async {
        let (m, index) = await model([doc("a.pdf", pages: [0, 2], matches: 5), doc("b.pdf", pages: [1], matches: 1)])
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        m.focusedPage = page("b.pdf", 1)
        // The index changed (a new file indexed): the same term is searched again in the background.
        index.hits = [doc("c.pdf", pages: [0], matches: 9), doc("a.pdf", pages: [0, 2], matches: 5), doc("b.pdf", pages: [1], matches: 1)]
        await refresh(m)
        #expect(m.hits.map(\.relativePath) == ["c.pdf", "a.pdf", "b.pdf"])
        #expect(m.focusedPage == page("b.pdf", 1))
    }

    @Test func theUsersChoiceStaysWhenAFilterKeepsIt() async {
        let (m, _) = await model([doc("a.pdf", pages: [0]), doc("b.pdf", pages: [1])])
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        m.focusedPage = page("b.pdf", 1)
        m.extraFilters = [Excluding(name: "a.pdf")]
        await m.waitUntilIdle()
        #expect(m.focusedPage == page("b.pdf", 1))
    }

    @Test func theUsersChoiceThatTheSameSearchNoLongerShowsGivesWayToTheFirstHit() async {
        let (m, index) = await model([doc("a.pdf", pages: [0]), doc("b.pdf", pages: [1])])
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        m.focusedPage = page("b.pdf", 1)
        index.hits = [doc("a.pdf", pages: [0])]                 // b.pdf deleted
        await refresh(m)
        #expect(m.focusedPage == page("a.pdf", 0))
    }

    /// Review 1: a refresh of the same term (indexing, recognition, the Finder) does not move the shown page or
    /// scroll the grid while the user reads, even if another document is first now.
    @Test func aRefreshOfTheSameTermKeepsTheShownFirstHit() async {
        let (m, index) = await model([doc("a.pdf", pages: [3], matches: 5)])
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.focusedPage == page("a.pdf", 3))
        index.hits = [doc("c.pdf", pages: [7], matches: 9), doc("a.pdf", pages: [3], matches: 5)]
        await refresh(m)
        #expect(m.hits.map(\.relativePath) == ["c.pdf", "a.pdf"])
        #expect(m.focusedPage == page("a.pdf", 3))
    }

    @Test func aSortChangeKeepsTheShownFirstHit() async {
        let (m, _) = await model([doc("b.pdf", pages: [1], matches: 9), doc("a.pdf", pages: [2], matches: 1)])
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.focusedPage == page("b.pdf", 1))
        m.settings.sort = .fileName
        await m.waitUntilIdle()
        #expect(m.hits.map(\.relativePath) == ["a.pdf", "b.pdf"])
        #expect(m.focusedPage == page("b.pdf", 1))
    }

    /// Review 2: early rows of a slow search do not set the preview; the final list does, once.
    @Test func earlyRowsDoNotSetThePreviewTheFinalListDoesOnce() async {
        let index = FakeIndex()
        index.partialHits = [doc("a.pdf", pages: [0], matches: 1)]
        index.hits = [doc("b.pdf", pages: [4], matches: 9), doc("a.pdf", pages: [0], matches: 1)]
        index.holdSearches = true
        let m = makeModel(index: index)
        await m.open(folder: folder)
        await m.waitUntilIdle()
        var shown: [PageRef?] = []
        m.queryText = "ver*"
        #expect(await eventually(.seconds(2)) { m.hits.map(\.relativePath) == ["a.pdf"] })
        shown.append(m.focusedPage)
        index.holdSearches = false
        await m.waitUntilIdle()
        shown.append(m.focusedPage)
        #expect(shown == [nil, page("b.pdf", 4)])
    }

    @Test func clearingTheSearchKeepsTheShownPageLikeAChosenOne() async {
        let index = FakeIndex()
        index.hits = [doc("a.pdf", pages: [1])]
        var listed = doc("a.pdf", pages: [])
        listed = DocumentHit(url: listed.url, relativePath: listed.relativePath, modifiedAt: listed.modifiedAt, pageHits: [],
                             totalMatches: 0, relevance: 0, sourceRoot: listed.sourceRoot, pageCount: 3)
        index.browseList = [listed]
        let m = makeModel(index: index)
        await m.open(folder: folder)
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.focusedPage == page("a.pdf", 1))
        m.queryText = ""
        await m.waitUntilIdle()
        #expect(m.isBrowsing)
        #expect(m.focusedPage == page("a.pdf", 1), "browsing keeps a shown page, as it kept a chosen one before")
    }

    @Test func noHitsLeaveThePreviewEmpty() async {
        let (m, index) = await model([doc("a.pdf", pages: [0])])
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        index.hits = []
        m.queryText = "Xylophon"
        await m.waitUntilIdle()
        #expect(m.focusedPage == nil)
    }

    @Test func browsingFocusesNothing() async {
        let index = FakeIndex()
        index.browseList = [doc("a.pdf", pages: []), doc("b.pdf", pages: [])]
        let m = makeModel(index: index)
        await m.open(folder: folder)
        await m.waitUntilIdle()
        #expect(m.isBrowsing)
        #expect(m.focusedPage == nil)
    }

    @Test func aHitOnlyInTheFileNameFocusesTheFirstPage() async {
        var named = doc("vertrag.docx", pages: [])
        named = DocumentHit(url: named.url, relativePath: named.relativePath, modifiedAt: named.modifiedAt, pageHits: [],
                            totalMatches: 0, relevance: 0, sourceRoot: named.sourceRoot, pageCount: 3, kind: .word, nameMatch: true)
        let (m, _) = await model([named])
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.focusedPage == page("vertrag.docx", 0))
    }

    @Test func allPagesShownStillFocusesTheFirstHitPage() async {
        let settings = makeSettings()
        settings.showAllPages = true
        var hit = doc("a.pdf", pages: [2, 4])
        hit = DocumentHit(url: hit.url, relativePath: hit.relativePath, modifiedAt: hit.modifiedAt, pageHits: hit.pageHits,
                          totalMatches: 2, relevance: 0, sourceRoot: hit.sourceRoot, pageCount: 6)
        let (m, _) = await model([hit], settings: settings)
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.focusedPage == page("a.pdf", 2), "the first hit page, not page 1 of „Alle Seiten“")
    }

    /// The page shown by the model itself (for the first ↓ from the search field, Chris 2026-11-14).
    @Test func theFirstHitIsAutomaticUntilTheUserChoosesAPage() async {
        let (m, _) = await model([doc("a.pdf", pages: [0, 2]), doc("b.pdf", pages: [1])])
        #expect(!m.focusIsAutomatic, "nothing shown")
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.focusedPage == page("a.pdf", 0))
        #expect(m.focusIsAutomatic)
        m.focusedPage = page("a.pdf", 0)                      // the first ↓ enters on it: the user's choice now
        #expect(!m.focusIsAutomatic)
    }

    @Test func aShownPageIsNotAutomaticWhileBrowsing() async {
        let index = FakeIndex()
        index.hits = [doc("a.pdf", pages: [1])]
        var listed = doc("a.pdf", pages: [])
        listed = DocumentHit(url: listed.url, relativePath: listed.relativePath, modifiedAt: listed.modifiedAt, pageHits: [],
                             totalMatches: 0, relevance: 0, sourceRoot: listed.sourceRoot, pageCount: 3)
        index.browseList = [listed]
        let m = makeModel(index: index)
        await m.open(folder: folder)
        m.queryText = "Vertrag"
        await m.waitUntilIdle()
        #expect(m.focusIsAutomatic)
        m.queryText = ""
        await m.waitUntilIdle()
        #expect(m.focusedPage == page("a.pdf", 1))
        #expect(!m.focusIsAutomatic, "↓ from the field moves on while browsing, as before")
    }
}
