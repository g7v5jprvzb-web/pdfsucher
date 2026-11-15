import Foundation
import PDFKit
import IndexKit
import OfficeKit
import OutputKit
import SearchKit
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// AppModel against the real IndexStore / Indexer / SearchService, with PDFs made by PDFFixtures.
/// Each test keeps its index file in its own temp directory (not in Application Support).
@MainActor @Suite("AppModel with the real index")
struct RealIndexTests {
    let base: URL
    let folder: URL
    let indexURL: URL

    init() throws {
        base = try PDFFixtures.tempDirectory()
        folder = base.appendingPathComponent("PDFs", isDirectory: true)
        indexURL = base.appendingPathComponent("index.sqlite")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try PDFFixtures.makePDF(at: folder.appendingPathComponent("vertrag.pdf"),
                                pages: ["Der Vertrag beginnt heute.", "Nichts.", "Vertrag Ende."])
        try PDFFixtures.makePDF(at: folder.appendingPathComponent("angebot.pdf"), pages: ["Ein Angebot zum Vertrag."])
    }

    func makeRealModel(defaults: UserDefaults? = nil, environment: FakeEnvironment = FakeEnvironment()) -> AppModel {
        let indexURL = self.indexURL
        return AppModel(settings: makeSettings(),
                        defaults: defaults ?? UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!,
                        environment: environment, slideCache: testSlideCache, debounce: .zero,
                        openIndex: { root in try FolderIndex.shared(root: root, indexURL: indexURL, slideCache: testSlideCache) }, officeRendering: PowerPointDisplaySetting())
    }

    @Test func searchWorksWhenFolderUnreachable() async throws {
        let model = makeRealModel()
        await model.open(folder: folder)
        await model.waitUntilIdle()
        #expect(model.indexStatus == .upToDate)

        try FileManager.default.moveItem(at: folder, to: base.appendingPathComponent("weg"))
        await model.open(folder: folder)
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        #expect(model.indexStatus == .unreachable)
        #expect(Set(model.hits.map(\.relativePath)) == ["vertrag.pdf", "angebot.pdf"])
        #expect(model.hits.first { $0.relativePath == "vertrag.pdf" }?.pageHits.map(\.pageIndex) == [0, 2])
    }

    @Test func sameFolderReusesIndex() throws {
        let a = try FolderIndex.shared(root: folder, indexURL: indexURL, slideCache: testSlideCache)
        let b = try FolderIndex.shared(root: folder.appendingPathComponent("."), indexURL: indexURL, slideCache: testSlideCache)
        #expect(a === b)
    }

    @Test func damagedIndexFileShowsHint() async throws {
        try Data(repeating: 0x42, count: 8192).write(to: indexURL)
        let model = makeRealModel()
        await model.open(folder: folder)
        #expect(model.notice == "Index war beschädigt und wird neu aufgebaut")
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        #expect(model.notice == nil)
        #expect(model.hits.count == 2)
    }

    @Test func singleFileSearch() async throws {
        let model = makeRealModel()
        model.open(file: folder.appendingPathComponent("vertrag.pdf"))
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        #expect(model.hits.count == 1)
        #expect(model.hits.first?.pageHits.map(\.pageIndex) == [0, 2])
        #expect(model.hits.first?.url == folder.appendingPathComponent("vertrag.pdf"))
        #expect(model.indexStatus == .none)
    }

    @Test func singleFileWithoutTextShowsScanHint() async throws {
        let scan = folder.appendingPathComponent("scan.pdf")
        try PDFFixtures.makePDF(at: scan, pages: ["", " "])
        let model = makeRealModel()
        model.open(file: scan)
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        #expect(model.hits.isEmpty)
        #expect(model.notice == "Im PDF wurde kein Text erkannt")   // 1.2 §8: recognition ran and found nothing
    }

    @Test func singleFileUnreadableShowsHint() async throws {
        let broken = folder.appendingPathComponent("kaputt.pdf")
        try Data("kein pdf".utf8).write(to: broken)
        let model = makeRealModel()
        model.open(file: broken)
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        #expect(model.hits.isEmpty)
        #expect(model.notice == "PDF kann nicht gelesen werden (beschädigt oder passwortgeschützt)")
    }

    /// Searches „Vertrag“ in the fixture folder and ticks angebot.pdf p.1 and vertrag.pdf p.3.
    func modelWithSelection(_ env: FakeEnvironment) async -> AppModel {
        let model = makeRealModel(environment: env)
        await model.open(folder: folder)
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        for hit in model.hits {
            model.selection.toggle(PageRef(url: hit.url, pageIndex: hit.pageHits.last!.pageIndex))
        }
        return model
    }

    @Test func saveWritesSelectionInGridOrder() async throws {
        let env = FakeEnvironment()
        env.saveURL = base.appendingPathComponent("Auswahl.pdf")
        let model = await modelWithSelection(env)
        #expect(model.hits.map(\.relativePath) == ["vertrag.pdf", "angebot.pdf"])
        model.saveSelection()
        await model.waitUntilIdle()
        #expect(model.alertMessage == nil)
        let merged = try #require(PDFDocument(url: env.saveURL!))
        #expect(merged.pageCount == 2)
        #expect(merged.page(at: 0)?.string?.contains("Vertrag Ende") == true)
        #expect(merged.page(at: 1)?.string?.contains("Angebot") == true)
        #expect(model.selection.count == 2)
    }

    /// Spec 1.1 §8: with „Alle Seiten“ a page without a hit can be ticked and lands in the new PDF.
    @Test func tickedPageWithoutHitIsSaved() async throws {
        let env = FakeEnvironment()
        env.saveURL = base.appendingPathComponent("Alle.pdf")
        let model = makeRealModel(environment: env)
        await model.open(folder: folder)
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        let vertrag = try #require(model.hits.first { $0.relativePath == "vertrag.pdf" })
        #expect(vertrag.pageCount == 3)                       // realSearchFillsPageCount
        #expect(!vertrag.pageHits.contains { $0.pageIndex == 1 })
        model.selection.toggle(PageRef(url: vertrag.url, pageIndex: 1))
        model.saveSelection()
        await model.waitUntilIdle()
        let merged = try #require(PDFDocument(url: env.saveURL!))
        #expect(merged.pageCount == 1)
        #expect(merged.page(at: 0)?.string?.contains("Nichts") == true)
    }

    /// Switching „Alle Seiten“ off moves the focus from a hidden page to the nearest hit page.
    @Test func switchingAllPagesOffMovesFocusToAHitPage() async throws {
        let model = makeRealModel()
        model.settings.showAllPages = true
        await model.open(folder: folder)
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        let vertrag = try #require(model.hits.first { $0.relativePath == "vertrag.pdf" })
        model.focusedPage = PageRef(url: vertrag.url, pageIndex: 1)
        model.settings.showAllPages = false
        await model.waitUntilIdle()
        #expect(model.focusedPage == PageRef(url: vertrag.url, pageIndex: 0) || model.focusedPage == PageRef(url: vertrag.url, pageIndex: 2))
    }

    /// With „Alle Seiten“ a focused page without a hit stays focused after the next search result.
    @Test func focusOnNonHitPageSurvivesWithAllPages() async throws {
        let model = makeRealModel()
        model.settings.showAllPages = true
        await model.open(folder: folder)
        model.queryText = "Vertrag"
        await model.waitUntilIdle()
        let vertrag = try #require(model.hits.first { $0.relativePath == "vertrag.pdf" })
        model.focusedPage = PageRef(url: vertrag.url, pageIndex: 1)
        model.queryText = "Vertrag "
        await model.waitUntilIdle()
        #expect(model.focusedPage == PageRef(url: vertrag.url, pageIndex: 1))
    }

    @Test func saveCancelledWritesNothing() async throws {
        let env = FakeEnvironment()
        let model = await modelWithSelection(env)
        model.saveSelection()
        await model.waitUntilIdle()
        #expect(model.alertMessage == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasSuffix(".pdf") }.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["angebot.pdf", "vertrag.pdf"])
    }

    @Test func printUsesDefaultFileNameAsJobTitle() async throws {
        let env = FakeEnvironment()
        let model = await modelWithSelection(env)
        let before = Date()
        model.printSelection()
        await model.waitUntilIdle()
        let names = [before, Date()].map { String(DefaultFileName.make(searchTerm: "Vertrag", date: $0).dropLast(4)) }
        #expect(env.printed.count == 1)
        #expect(names.contains(env.printed.first?.jobTitle ?? ""))   // either side of midnight
    }

    @Test(.enabled(if: getuid() != 0, "root ignores directory permissions"))
    func saveFailureShowsReasonAndKeepsSelection() async throws {
        let locked = base.appendingPathComponent("nur-lesen", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let env = FakeEnvironment()
        env.saveURL = locked.appendingPathComponent("Auswahl.pdf")
        let model = await modelWithSelection(env)
        model.saveSelection()
        await model.waitUntilIdle()
        let message = try #require(model.alertMessage)
        #expect(message == "Speichern fehlgeschlagen: Auswahl.pdf – Kein Schreibrecht für den Ordner „nur-lesen“")
        #expect(model.selection.count == 2)
    }

    /// Spec 1.3 Teil B: browsing without a query carries the document kind and the „vereinfacht“ hint.
    @Test func browseCarriesDocumentKind() async throws {
        let root = base.appendingPathComponent("Gemischt", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PDFFixtures.makePDF(at: root.appendingPathComponent("a.pdf"), pages: ["Stichwort im PDF"])
        try ImageFixtures.makeImage(at: root.appendingPathComponent("b.png"), text: "Bild", size: CGSize(width: 200, height: 100),
                                    format: .png)
        try Data("x".utf8).write(to: root.appendingPathComponent("c.docx"))
        try Data("x".utf8).write(to: root.appendingPathComponent("d.pptx"))
        let kindIndexURL = base.appendingPathComponent("kinds.sqlite")
        let store = try IndexStore(fileURL: kindIndexURL, root: root)
        _ = try await Indexer(root: root, store: store, ocr: KindFixedOCR(), layout: KindFixedLayout()).update { _ in }

        let entries = try FolderIndex(root: root, indexURL: kindIndexURL, slideCache: testSlideCache).browse()
        let kinds = Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0.kind) })
        #expect(kinds == ["a.pdf": .pdf, "b.png": .image, "c.docx": .word, "d.pptx": .powerpoint])
        #expect(entries.filter(\.isImage).map(\.relativePath) == ["b.png"])
        #expect(entries.filter(\.isSimplified).map(\.relativePath) == ["c.docx"])
    }

    /// Office smoke run (1.3 Teil B): hit URLs of files in a folder with an umlaut carry the decomposed path, the index
    /// stores the precomposed one; the word boxes (slide highlights) must still be found.
    @Test func layoutWordsOfFileInUmlautFolderAreFound() async throws {
        let decks = folder.appendingPathComponent("Präsentationen", isDirectory: true)
        try FileManager.default.createDirectory(at: decks, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: decks.appendingPathComponent("Übersicht.pptx"))
        let index = try FolderIndex(root: folder.standardizedFileURL, indexURL: indexURL, makeLayout: { WordsLayout() })
        let model = AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!,
                             environment: FakeEnvironment(), slideCache: testSlideCache, debounce: .zero, openIndex: { _ in index }, officeRendering: PowerPointDisplaySetting())
        await model.open(folder: folder)
        await model.waitUntilIdle()
        model.queryText = "Kündigungsfrist"
        await model.waitUntilIdle()
        let hit = try #require(model.hits.first { $0.kind == .powerpoint })
        let words = await model.ocrText(for: PageRef(url: hit.url, pageIndex: 0))?.words
        #expect(words?.count == 1, "\(hit.url.path)")
    }

    @Test func saveMessageUsesReason() {
        let url = URL(fileURLWithPath: "/x/Auswahl.pdf")
        #expect(AppModel.message(forSaveError: OutputError.writeFailed(url, reason: "Kein Schreibrecht"), url: url)
                == "Speichern fehlgeschlagen: Auswahl.pdf – Kein Schreibrecht")
    }
}

private struct KindFixedOCR: OCRSource {
    func recognize(pageIndex: Int, of url: URL, kind: DocumentKind) throws -> OCRResult {
        OCRResult(text: "Stichwort im Bild", words: [])
    }
}

/// Word as `textkit` („vereinfacht“), PowerPoint as `quicklook`; one page each.
private struct KindFixedLayout: PageLayoutSource {
    func renderer(for kind: DocumentKind) -> (name: String, version: Int) { (kind == .word ? "textkit" : "quicklook", 1) }
    func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        let (name, version) = renderer(for: kind)
        return LayoutResult(pages: [LaidOutPage(text: "Stichwort", words: [], size: CGSize(width: 595, height: 842))],
                            renderer: name, layoutVersion: version)
    }
}

/// PowerPoint with one slide holding „Kündigungsfrist“ and its word box (like Quick Look slides).
private struct WordsLayout: PageLayoutSource {
    func renderer(for kind: DocumentKind) -> (name: String, version: Int) { ("quicklook", 1) }
    func layout(of url: URL, kind: DocumentKind) async throws -> LayoutResult {
        LayoutResult(pages: [LaidOutPage(text: "Kündigungsfrist", words: [OCRWord(range: NSRange(location: 0, length: 15),
                                                                                   box: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05))],
                                         size: CGSize(width: 720, height: 540))],
                     renderer: "quicklook", layoutVersion: 1)
    }
}
