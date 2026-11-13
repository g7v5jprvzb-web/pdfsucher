import Foundation
import OutputKit
import SearchKit
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// 1.2.2 §1: when a search term goes into the history.
@MainActor @Suite("Search history triggers", .timeLimit(.minutes(1)))
struct SearchHistoryTriggerTests {
    let folder = URL(fileURLWithPath: "/docs", isDirectory: true)

    func model(hits: [DocumentHit] = [doc("a.pdf", pages: [0, 2])]) async -> AppModel {
        let index = FakeIndex()
        index.hits = hits
        let m = makeModel(index: index)
        m.historyDelay = .milliseconds(40)
        await m.open(folder: folder)
        await m.waitUntilIdle()
        return m
    }

    @Test func idleWithHitsCommits() async {
        let m = await model()
        m.queryText = "Vertrag"
        await m.waitForSearch()
        #expect(m.searchHistory.entries.isEmpty, "not at once")
        #expect(await eventually { m.searchHistory.entries == ["Vertrag"] })
    }

    @Test func idleWithoutHitsDoesNot() async throws {
        let m = await model(hits: [])
        m.queryText = "Xylophon"
        await m.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(150))
        #expect(m.searchHistory.entries.isEmpty)
    }

    @Test func typingCancelsIdle() async throws {
        let m = await model()
        m.historyDelay = .milliseconds(200)
        m.queryText = "Ver"
        await m.waitForSearch()
        m.queryText = "Vertrag"
        await m.waitForSearch()
        #expect(await eventually { m.searchHistory.entries == ["Vertrag"] })
        try await Task.sleep(for: .milliseconds(250))
        #expect(m.searchHistory.entries == ["Vertrag"], "„Ver“ never stored")
    }

    @Test func explicitArrivalsCommit() async {
        let m = await model()
        m.historyDelay = .seconds(60)
        m.queryText = "Miete"
        await m.waitForSearch()
        m.noteSearchArrived()                                 // Return in the field
        #expect(m.searchHistory.entries == ["Miete"])
        m.queryText = "Angebot"
        await m.waitForSearch()
        m.focusedPage = PageRef(url: folder.appendingPathComponent("a.pdf"), pageIndex: 2)     // tile click, arrow
        #expect(m.searchHistory.entries.first == "Angebot")
        m.queryText = "Kündigung"
        await m.waitForSearch()
        m.selection.toggle(PageRef(url: folder.appendingPathComponent("a.pdf"), pageIndex: 0))   // tick
        #expect(m.searchHistory.entries.first == "Kündigung")
        #expect(m.searchHistory.entries.count == 3)
    }

    @Test func browsingStoresNothing() async {
        let m = await model()
        m.focusedPage = PageRef(url: folder.appendingPathComponent("a.pdf"), pageIndex: 0)
        m.selection.toggle(PageRef(url: folder.appendingPathComponent("a.pdf"), pageIndex: 0))
        #expect(m.searchHistory.entries.isEmpty)
    }

    /// Review I2: a refresh (indexing, recognition, sorting) shows the result again but stores nothing more.
    @Test func refreshDoesNotRecommit() async throws {
        let m = await model()
        m.queryText = "Vertrag"
        await m.waitForSearch()
        #expect(await eventually { m.searchHistory.entries == ["Vertrag"] })
        m.searchHistory.commit("Miete")
        m.settings.sort = .fileName                        // the same query is shown again
        await m.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(150))
        #expect(m.searchHistory.entries == ["Miete", "Vertrag"])
    }

    /// Review M3: a text that is no query („-“ alone) is never stored.
    @Test func nonQueryTextNotStored() async throws {
        let m = await model()
        m.queryText = "-"
        await m.waitUntilIdle()
        m.noteSearchArrived()
        try await Task.sleep(for: .milliseconds(150))
        #expect(m.searchHistory.entries.isEmpty)
    }

    /// Review M1: clearing or pruning several ticks at once (no user tick) stores nothing.
    @Test func bulkSelectionChangeDoesNotCommit() async {
        let m = await model()
        m.historyDelay = .seconds(60)
        m.selection.toggle(PageRef(url: folder.appendingPathComponent("a.pdf"), pageIndex: 0))
        m.selection.toggle(PageRef(url: folder.appendingPathComponent("a.pdf"), pageIndex: 2))
        m.queryText = "Ver"
        await m.waitForSearch()
        m.selection.clear()
        #expect(m.searchHistory.entries.isEmpty)
    }

    @Test func chooseRunsSearchAndMovesUp() async {
        let m = await model()
        m.searchHistory.commit("Vertrag")
        m.searchHistory.commit("Miete")
        m.chooseHistoryEntry("Vertrag")
        #expect(m.queryText == "Vertrag")
        await m.waitForSearch()
        #expect(m.query.terms.isEmpty == false)
        #expect(m.searchHistory.entries == ["Vertrag", "Miete"])
    }
}
