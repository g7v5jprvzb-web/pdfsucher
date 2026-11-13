import Foundation
import PDFKit
import IndexKit
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
                        environment: environment, debounce: .zero,
                        openIndex: { root in try FolderIndex.shared(root: root, indexURL: indexURL) })
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
        let a = try FolderIndex.shared(root: folder, indexURL: indexURL)
        let b = try FolderIndex.shared(root: folder.appendingPathComponent("."), indexURL: indexURL)
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

    @Test func saveMessageUsesReason() {
        let url = URL(fileURLWithPath: "/x/Auswahl.pdf")
        #expect(AppModel.message(forSaveError: OutputError.writeFailed(url, reason: "Kein Schreibrecht"), url: url)
                == "Speichern fehlgeschlagen: Auswahl.pdf – Kein Schreibrecht")
    }
}
