import Foundation
import IndexKit
import OutputKit
import PDFKit
import SearchKit
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Spec 1.3 §8a: the „Dateitypen“ filter on search and browse results, the summary from the filtered
/// set, no new search on a change, and ticked pages that stay selected while their kind is hidden.
@MainActor @Suite("File type filter in the model")
struct FileKindsFilterModelTests {
    let folder = URL(fileURLWithPath: "/docs")

    func hit(_ name: String, _ kind: DocumentKind, pages: [Int], matches: Int, root: URL = URL(fileURLWithPath: "/docs"),
             pageCount: Int = 0) -> DocumentHit {
        DocumentHit(url: root.appendingPathComponent(name), relativePath: name, modifiedAt: .distantPast,
                    pageHits: pages.map { PageHit(pageIndex: $0, matchCount: 1) }, totalMatches: matches, relevance: 0,
                    sourceRoot: root, pageCount: pageCount, kind: kind)
    }

    var mixed: [DocumentHit] {
        [hit("a.pdf", .pdf, pages: [0, 1], matches: 9), hit("b.docx", .word, pages: [0], matches: 7),
         hit("c.pptx", .powerpoint, pages: [0, 2, 3], matches: 5), hit("d.jpg", .image, pages: [0], matches: 3)]
    }

    @Test func filterAppliesToSearchAndSummary() async {
        let index = FakeIndex()
        index.hits = mixed
        let model = makeModel(index: index)
        await model.open(folder: folder)
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        #expect(model.hits.count == 4)
        #expect(model.summary == "Gefunden in 4 Dokumenten, 7 Seiten")
        model.settings.fileKinds = [.pdf, .word]
        await model.waitUntilIdle()
        #expect(model.hits.map(\.relativePath) == ["a.pdf", "b.docx"])
        #expect(model.summary == "Gefunden in 2 Dokumenten, 3 Seiten · 2 ausgeblendet")
        #expect(model.hiddenByFilter == 2)
        // The next search keeps the filter.
        model.queryText = "Vertrag Angebot"
        await model.waitUntilIdle()
        #expect(model.hits.map(\.relativePath) == ["a.pdf", "b.docx"])
        model.settings.fileKinds = Set(GridSettings.allFileKinds)
        await model.waitUntilIdle()
        #expect(model.hits.count == 4)
        #expect(model.summary == "Gefunden in 4 Dokumenten, 7 Seiten")
        #expect(model.hiddenByFilter == 0)
    }

    @Test func filterAppliesToBrowse() async {
        let index = FakeIndex()
        index.browseList = [hit("a.pdf", .pdf, pages: [], matches: 0, pageCount: 4),
                            hit("b.docx", .word, pages: [], matches: 0, pageCount: 2),
                            hit("d.jpg", .image, pages: [], matches: 0, pageCount: 1)]
        let model = makeModel(index: index)
        await model.open(folder: folder)
        await model.waitUntilIdle()
        #expect(model.isBrowsing)
        #expect(model.summary == "3 Dateien, 7 Seiten")
        model.settings.fileKinds = [.image]
        await model.waitUntilIdle()
        #expect(model.hits.map(\.relativePath) == ["d.jpg"])
        #expect(model.summary == "1 Datei, 1 Seite · 2 ausgeblendet")
        #expect(model.hiddenByFilter == 2)
    }

    @Test func filterChangeDoesNotSearchAgain() async {
        let index = FakeIndex()
        index.hits = mixed
        let model = makeModel(index: index)
        await model.open(folder: folder)
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        let searches = index.searchCount
        let updates = index.events.filter { $0 == "update-start" }.count
        model.settings.toggleFileKind(.powerpoint)
        model.settings.toggleFileKind(.image)
        await model.waitUntilIdle()
        #expect(model.hits.count == 2)
        #expect(index.searchCount == searches)
        #expect(index.events.filter { $0 == "update-start" }.count == updates, "no indexing")
    }

    @Test func combinationsFilter() async {
        let index = FakeIndex()
        index.hits = mixed
        let model = makeModel(index: index)
        await model.open(folder: folder)
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        let all = GridSettings.allFileKinds
        for mask in 1..<(1 << all.count) {
            let kinds = Set(all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            model.settings.fileKinds = kinds
            await model.waitUntilIdle()
            #expect(model.hits.allSatisfy { kinds.contains($0.kind) }, "\(kinds)")
            #expect(model.hits.count == kinds.count, "\(kinds)")
        }
    }

    @Test func focusOnHiddenPageIsCleared() async {
        let index = FakeIndex()
        index.hits = mixed
        let model = makeModel(index: index)
        await model.open(folder: folder)
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        let word = PageRef(url: folder.appendingPathComponent("b.docx"), pageIndex: 0)
        model.focusedPage = word
        model.settings.toggleFileKind(.word)
        await model.waitUntilIdle()
        #expect(model.focusedPage != word)
        // 1.3.3: the hidden page was the user's; the preview shows the first shown hit instead of nothing.
        #expect(model.focusedPage != nil)
        #expect(model.focusedPage == FocusNavigator.firstHit(in: model.hits))
    }

    /// Review Focus 3: ticked pages of a hidden kind stay ticked, count, and are saved where they were.
    @Test func hiddenTickedPagesStayCountedAndAreSavedInOrder() async throws {
        let base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        let a = base.appendingPathComponent("a.pdf"), b = base.appendingPathComponent("b.pdf")
        try PDFFixtures.makePDF(at: a, pages: ["Erste PDF-Seite eins", "Erste PDF-Seite zwei"])
        let m = try OfficeFixtures.docx(paragraphs: ["Herr Müller"], name: "m.docx", in: base)
        try PDFFixtures.makePDF(at: b, pages: ["Letzte PDF-Seite"])
        let index = FakeIndex()
        // Grid order by match count: a.pdf, m.docx, b.pdf (a path order would put m.docx last).
        index.hits = [hit("a.pdf", .pdf, pages: [0, 1], matches: 9, root: base, pageCount: 2),
                      hit("m.docx", .word, pages: [0], matches: 5, root: base, pageCount: 1),
                      hit("b.pdf", .pdf, pages: [0], matches: 1, root: base, pageCount: 1)]
        let env = FakeEnvironment()
        env.saveURL = base.appendingPathComponent("Auswahl.pdf")
        let model = makeModel(index: index, environment: env)
        await model.open(folder: base)
        model.queryText = "Seite"
        await model.waitUntilIdle()
        #expect(model.hits.map(\.relativePath) == ["a.pdf", "m.docx", "b.pdf"])
        for ref in [PageRef(url: b, pageIndex: 0), PageRef(url: m, pageIndex: 0), PageRef(url: a, pageIndex: 1)] {
            model.selection.toggle(ref)
        }
        model.settings.toggleFileKind(.word)
        await model.waitUntilIdle()
        #expect(model.hits.map(\.relativePath) == ["a.pdf", "b.pdf"])
        #expect(model.selection.count == 3)
        #expect(model.selection.contains(PageRef(url: m, pageIndex: 0)))

        model.saveSelection()
        await model.waitUntilIdle()
        #expect(model.alertMessage == nil)
        let saved = try #require(PDFDocument(url: env.saveURL!))
        #expect(saved.pageCount == 3)
        #expect(saved.page(at: 0)?.string?.contains("Erste PDF-Seite zwei") == true)
        #expect(saved.page(at: 1)?.string?.contains("Müller") == true)
        #expect(saved.page(at: 2)?.string?.contains("Letzte") == true)
        #expect(model.selection.count == 3)
    }

    // MARK: Review fixes

    /// Review (Important): a filter that hides every result says so, also after a relaunch with the saved filter.
    @Test func everythingHiddenIsCounted() async {
        let index = FakeIndex()
        index.hits = [hit("a.pdf", .pdf, pages: [0], matches: 3), hit("b.pdf", .pdf, pages: [0, 1], matches: 2)]
        index.browseList = [hit("a.pdf", .pdf, pages: [], matches: 0, pageCount: 1)]
        let settings = makeSettings()
        settings.fileKinds = [.image]
        let model = makeModel(index: index, settings: settings)
        await model.open(folder: folder)
        await model.waitUntilIdle()
        #expect(model.isBrowsing && model.hits.isEmpty)
        #expect(model.hiddenByFilter == 1)
        #expect(model.summary == "0 Dateien, 0 Seiten · 1 ausgeblendet")
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        #expect(model.hits.isEmpty)
        #expect(model.hiddenByFilter == 2)
        #expect(model.summary == "Keine Treffer · 2 ausgeblendet")
        settings.showAllFileKinds()
        await model.waitUntilIdle()
        #expect(model.hits.count == 2 && model.hiddenByFilter == 0)
    }

    /// Review minor 1: early results that are all hidden do not replace the shown list (no empty flash).
    @Test func hiddenEarlyResultsDoNotFlashEmpty() async {
        let index = FakeIndex()
        index.hits = [hit("a.pdf", .pdf, pages: [0], matches: 3)]
        let settings = makeSettings()
        settings.fileKinds = [.pdf]
        let model = makeModel(index: index, settings: settings)
        await model.open(folder: folder)
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        #expect(model.hits.map(\.relativePath) == ["a.pdf"])
        var published: [[DocumentHit]] = []
        model.onHitsPublished = { published.append($0) }
        index.partialHits = [hit("b.docx", .word, pages: [0], matches: 1)]
        index.holdSearches = true
        model.queryText = "Vertrag Angebot"
        #expect(await eventually(.seconds(2)) { model.isSearching })
        try? await Task.sleep(for: .milliseconds(300))      // well past `earlyDelay`
        #expect(published.isEmpty, "hidden early rows publish nothing")
        #expect(model.hits.map(\.relativePath) == ["a.pdf"])
        index.holdSearches = false
        await model.waitUntilIdle()
        #expect(model.hits.map(\.relativePath) == ["a.pdf"])
    }

    /// Review minor 2: a term whose hits are all hidden is still a real search and goes into the history.
    @Test func historyCountsHiddenHits() async {
        let index = FakeIndex()
        index.hits = [hit("b.docx", .word, pages: [0], matches: 1)]
        let settings = makeSettings()
        settings.fileKinds = [.pdf]
        let model = makeModel(index: index, settings: settings)
        model.historyDelay = .milliseconds(40)
        await model.open(folder: folder)
        await model.waitUntilIdle()
        model.queryText = "Vertrag"
        await model.waitForSearch()
        #expect(model.hits.isEmpty)
        #expect(await eventually { model.searchHistory.entries == ["Vertrag"] })
    }
    // MARK: `typ:` in the search field

    /// `typ:word Vertrag` searches „Vertrag“ and shows only Word, for this search; the menu stays as it is.
    @Test func typedKindFiltersThisSearch() async {
        let index = FakeIndex()
        index.hits = mixed
        let settings = makeSettings()
        settings.fileKinds = [.pdf]
        let model = makeModel(index: index, settings: settings)
        await model.open(folder: folder)
        model.queryText = "typ:word Vertrag"
        await model.waitUntilIdle()
        #expect(model.query == QueryParser.parse("Vertrag", partialWords: settings.partialWords))
        #expect(model.hits.map(\.relativePath) == ["b.docx"], "the typed kind replaces the menu's")
        #expect(model.hiddenByFilter == 0)
        #expect(model.summary == "Gefunden in 1 Dokument, 1 Seite")
        #expect(settings.fileKinds == [.pdf], "the menu is untouched")
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        #expect(model.hits.map(\.relativePath) == ["a.pdf"], "without the shortcut the menu applies again")
    }

    /// `typ:pdf` alone browses the PDFs.
    @Test func typedKindAloneBrowses() async {
        let index = FakeIndex()
        index.browseList = [hit("a.pdf", .pdf, pages: [], matches: 0, pageCount: 4),
                            hit("b.docx", .word, pages: [], matches: 0, pageCount: 2)]
        let model = makeModel(index: index)
        await model.open(folder: folder)
        model.queryText = "typ:pdf"
        await model.waitUntilIdle()
        #expect(model.isBrowsing)
        #expect(model.hits.map(\.relativePath) == ["a.pdf"])
    }
}
