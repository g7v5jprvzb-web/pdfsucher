import Foundation
import IndexKit
import OfficeKit
import OutputKit
import SearchKit
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

@MainActor @Suite("AppModel with a fake index")
struct AppModelTests {
    let folder = URL(fileURLWithPath: "/docs")

    @Test func searchShowsHitsAndSummary() async {
        let index = FakeIndex()
        index.hits = [doc("a.pdf", pages: [0, 2])]
        let model = makeModel(index: index)
        await model.open(folder: folder)
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        #expect(model.hits.map(\.relativePath) == ["a.pdf"])
        #expect(model.summary == "Gefunden in 1 Dokument, 2 Seiten")
        #expect(model.query == QueryParser.parse("Vertrag", partialWords: false))
    }

    /// Spec 1.1 §12 replaces the 1.0 rule „empty query → no hits, empty summary“: it browses.
    @Test func emptyQueryBrowses() async {
        let index = FakeIndex()
        index.hits = [doc("a.pdf", pages: [0])]
        index.browseList = [doc("a.pdf", pages: []), doc("b.pdf", pages: [])]
        let model = makeModel(index: index)
        await model.open(folder: folder)
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        #expect(!model.summary.isEmpty)
        model.queryText = "   "
        await model.waitUntilIdle()
        #expect(model.isBrowsing)
        #expect(model.hits.map(\.relativePath) == ["a.pdf", "b.pdf"])
        #expect(model.summary == "2 Dateien, 0 Seiten")
        #expect(model.query.isEmpty)
    }

    @Test func focusMovesToTheFirstHitWhenItsPageDisappears() async {
        let index = FakeIndex()
        index.hits = [doc("a.pdf", pages: [0, 1])]
        let model = makeModel(index: index)
        await model.open(folder: folder)
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        let a = model.hits[0]
        model.focusedPage = PageRef(url: a.url, pageIndex: 0)
        model.queryText = "Vertrag Miete"     // page 0 still a hit (and the first one)
        await model.waitUntilIdle()
        #expect(model.focusedPage == PageRef(url: a.url, pageIndex: 0))
        index.hits = [doc("a.pdf", pages: [1])]
        model.queryText = "Miete"
        await model.waitUntilIdle()
        #expect(model.focusedPage == PageRef(url: a.url, pageIndex: 1), "1.3.3: page 0 is gone, the new term's first hit")
    }

    @Test func sortChangeDoesNotRequery() async {
        let index = FakeIndex()
        index.hits = [doc("b.pdf", pages: [0], matches: 1), doc("a.pdf", pages: [0], matches: 5)]
        let settings = makeSettings()
        let model = makeModel(index: index, settings: settings)
        await model.open(folder: folder)
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        #expect(model.hits.map(\.relativePath) == ["a.pdf", "b.pdf"])   // matchCount
        let searches = index.searchCount
        settings.sort = .fileName
        settings.sort = .modifiedDate
        settings.sort = .fileName
        await model.waitUntilIdle()
        #expect(index.searchCount == searches)
        #expect(model.hits.map(\.relativePath) == ["a.pdf", "b.pdf"])
        settings.sort = .matchCount
        index.hits = [doc("b.pdf", pages: [0], matches: 9), doc("a.pdf", pages: [0], matches: 5)]
        await model.waitUntilIdle()
        #expect(index.searchCount == searches)
        #expect(model.hits.map(\.relativePath) == ["a.pdf", "b.pdf"])   // old hits, re-sorted
    }

    @Test func partialWordsChangeRequeries() async {
        let index = FakeIndex()
        index.hits = [doc("a.pdf", pages: [0])]
        let settings = makeSettings()
        let model = makeModel(index: index, settings: settings)
        await model.open(folder: folder)
        model.queryText = "trag"
        await model.waitUntilIdle()
        let searches = index.searchCount
        settings.partialWords = true
        await model.waitUntilIdle()
        #expect(index.searchCount == searches + 1)
        #expect(model.query == QueryParser.parse("trag", partialWords: true))
    }

    @Test func selectionSurvivesNewSearch() async {
        let index = FakeIndex()
        index.hits = [doc("a.pdf", pages: [0, 1])]
        let model = makeModel(index: index)
        await model.open(folder: folder)
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        let ref = PageRef(url: model.hits[0].url, pageIndex: 1)
        model.selection.toggle(ref)
        index.hits = [doc("c.pdf", pages: [3])]
        model.queryText = "Miete"
        await model.waitUntilIdle()
        #expect(model.hits.map(\.relativePath) == ["c.pdf"])
        #expect(model.selection.contains(ref))
        #expect(model.selection.count == 1)
    }

    @Test func indexingReportsProgressThenStatus() async {
        let index = FakeIndex()
        index.holdUpdates = true
        let model = makeModel(index: index)
        let opening = Task { await model.open(folder: folder) }
        #expect(await eventually { model.indexStatus == .building(folder: 1, folders: 1, done: 0, total: 3) })
        index.holdUpdates = false
        await opening.value
        await model.waitUntilIdle()
        #expect(model.indexStatus == .upToDate)

        index.report = IndexReport(failed: ["kaputt.pdf"], noText: ["scan.pdf"])
        index.ocrReport = OCRReport(noText: ["scan.pdf"])    // 1.2: „ohne Text“ = also nothing recognized
        await model.open(folder: folder)
        await model.waitUntilIdle()
        #expect(model.indexStatus == .problems(failed: ["kaputt.pdf"], noText: ["scan.pdf"]))
    }

    @Test func indexingFinishRefreshesResults() async {
        let index = FakeIndex()
        index.holdUpdates = true
        let model = makeModel(index: index)
        model.queryText = "Vertrag"
        Task { await model.open(folder: folder) }
        #expect(await eventually { index.events.contains("update-start") })
        await model.waitForSearch()
        #expect(model.hits.isEmpty)
        index.hits = [doc("neu.pdf", pages: [0])]
        index.holdUpdates = false
        await model.waitUntilIdle()
        #expect(model.hits.map(\.relativePath) == ["neu.pdf"])
    }

    @Test func corruptIndexShowsHintAndReindexes() async {
        let index = FakeIndex()
        let model = makeModel(index: index)
        await model.open(folder: folder)
        await model.waitUntilIdle()
        #expect(index.events.filter { $0 == "update-start" }.count == 1)
        index.hits = [doc("a.pdf", pages: [0])]
        index.failNextSearch(with: IndexStoreError.corruptIndexRebuilt)
        index.holdUpdates = true
        model.queryText = "Vertrag"
        #expect(await eventually { index.events.filter { $0 == "update-start" }.count == 2 })
        await model.waitForSearch()
        #expect(model.hits.isEmpty)
        #expect(model.notice == "Index war beschädigt und wird neu aufgebaut")
        index.holdUpdates = false
        await model.waitUntilIdle()
        #expect(model.notice == nil)
        #expect(model.hits.map(\.relativePath) == ["a.pdf"])
    }

    @Test func rebuiltOnOpenShowsHint() async {
        let index = FakeIndex()
        index.wasRebuilt = true
        index.holdUpdates = true
        let model = makeModel(index: index)
        Task { await model.open(folder: folder) }
        #expect(await eventually { model.notice == "Index war beschädigt und wird neu aufgebaut" })
        index.holdUpdates = false
        await model.waitUntilIdle()
    }

    @Test func deleteIndexCancelsIndexerFirst() async {
        let index = FakeIndex()
        index.holdUpdates = true
        let model = makeModel(index: index)
        Task { await model.open(folder: folder) }
        #expect(await eventually { index.events == ["update-start"] })
        await model.deleteIndex()
        #expect(Array(index.events.prefix(3)) == ["update-start", "update-cancelled", "delete"])
        #expect(await eventually { index.events.count == 4 })
        #expect(index.events[3] == "update-start")   // re-indexing after the delete
        index.holdUpdates = false
        await model.waitUntilIdle()
        #expect(model.indexStatus == .upToDate)
    }

    @Test func openingAnotherFolderCancelsIndexer() async {
        let first = FakeIndex()
        first.holdUpdates = true
        let second = FakeIndex()
        let model = AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!,
                             environment: FakeEnvironment(), slideCache: testSlideCache, debounce: .zero,
                             openIndex: { $0.lastPathComponent == "eins" ? first : second }, officeRendering: PowerPointDisplaySetting())
        Task { await model.open(folder: URL(fileURLWithPath: "/eins")) }
        #expect(await eventually { first.events == ["update-start"] })
        await model.open(folder: URL(fileURLWithPath: "/zwei"))
        #expect(first.events == ["update-start", "update-cancelled"])
        await model.waitUntilIdle()
        #expect(second.events == ["update-start", "update-end"])
        #expect(model.indexStatus == .upToDate)
    }

    @Test func remembersLastFolder() async throws {
        let defaults = UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!
        let index = FakeIndex()
        let model = AppModel(settings: makeSettings(), defaults: defaults, environment: FakeEnvironment(), slideCache: testSlideCache,
                             debounce: .zero, openIndex: { _ in index }, officeRendering: PowerPointDisplaySetting())
        let folder = try PDFFixtures.tempDirectory().appendingPathComponent("Verträge", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await model.open(folder: folder)
        #expect(defaults.stringArray(forKey: "sources") == [folder.standardizedFileURL.path])

        let opened = URLRecorder()
        let next = AppModel(settings: makeSettings(), defaults: defaults, environment: FakeEnvironment(), slideCache: testSlideCache,
                            debounce: .zero, openIndex: { opened.append($0); return index }, officeRendering: PowerPointDisplaySetting())
        await next.restoreSources()
        await next.waitUntilIdle()
        #expect(opened.urls.map(\.path) == [folder.resolvingSymlinksInPath().path])
    }

    @Test func pageRefsComeFromDocumentHitURLs() async {
        let index = FakeIndex()
        index.hits = [doc("a.pdf", pages: [0])]
        let env = FakeEnvironment()
        let model = makeModel(index: index, environment: env)
        await model.open(folder: folder)
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        model.openInPreview(PageRef(url: model.hits[0].url, pageIndex: 0))
        #expect(env.opened == [model.hits[0].url])
    }
}
