import Foundation
import PDFKit
import IndexKit
import OfficeKit
import OutputKit
import Synchronization
import Testing
import TestSupport
@testable import AppCore

/// A provider for `.docx` that counts `makePage` and draws an empty A4 page.
private final class CountingProvider: ForeignPageProvider {
    private let calls = Mutex(0)
    var makePageCalls: Int { calls.withLock { $0 } }

    func handles(_ url: URL) -> Bool { url.pathExtension.lowercased() == "docx" }
    func pageCount(of url: URL) -> Int? { 1 }
    func makePage(_ ref: PageRef) throws -> PDFPage {
        calls.withLock { $0 += 1 }
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        guard let page = document.page(at: 0) else { throw OutputError.cannotOpen(ref.url) }
        return page
    }
}

/// 1.3 Teil B Task 6: saving and printing with Word/PowerPoint pages, „Fehlende Seiten entfernen“ for
/// Office pages, and opening an Office original with the default app.
@MainActor @Suite("Office output", .serialized)
struct OfficeOutputTests {
    let base: URL
    /// This suite's own slide cache (never the user's, Task 9 M1).
    let slides: SlideCache

    init() throws {
        base = try PDFFixtures.tempDirectory()
        slides = SlideCache(root: base.appendingPathComponent("SlideCache", isDirectory: true))
    }

    func model(_ env: FakeEnvironment, foreignPages: (any ForeignPageProvider)? = nil, renderer: String? = nil) -> AppModel {
        let defaults = UserDefaults(suiteName: "AppCoreTests-\(UUID().uuidString)")!
        if let renderer { defaults.set(renderer, forKey: "office.powerPointRenderer") }
        return AppModel(settings: makeSettings(), defaults: defaults, environment: env, slideCache: slides, debounce: .zero,
                        foreignPages: foreignPages, officeRendering: PowerPointDisplaySetting())
    }

    @Test func savesMixedSelectionInOrder() async throws {
        let a = base.appendingPathComponent("a.pdf"), c = base.appendingPathComponent("c.pdf")
        try PDFFixtures.makePDF(at: a, pages: ["Erste PDF-Seite"])
        let b = try OfficeFixtures.docx(paragraphs: ["Herr Müller"], name: "b.docx", in: base)
        try PDFFixtures.makePDF(at: c, pages: ["Letzte PDF-Seite"])
        let env = FakeEnvironment()
        env.saveURL = base.appendingPathComponent("Auswahl.pdf")
        let model = model(env)
        for url in [a, b, c] { model.selection.toggle(PageRef(url: url, pageIndex: 0)) }

        model.saveSelection()
        await model.waitUntilIdle()
        #expect(model.alertMessage == nil)
        let saved = try #require(PDFDocument(url: env.saveURL!))
        #expect(saved.pageCount == 3)
        #expect(saved.page(at: 1)?.string?.contains("Müller") == true)
        #expect(saved.page(at: 0)?.string?.contains("Erste") == true)
        #expect(saved.page(at: 2)?.string?.contains("Letzte") == true)
    }

    @Test func printBuildsWithForeignProvider() async throws {
        let docx = try OfficeFixtures.docx(paragraphs: ["Druck"], name: "d.docx", in: base)
        let provider = CountingProvider()
        let env = FakeEnvironment()
        let model = model(env, foreignPages: provider)
        model.selection.toggle(PageRef(url: docx, pageIndex: 0))

        model.printSelection()
        await model.waitUntilIdle()
        #expect(model.alertMessage == nil)
        #expect(env.printed.count == 1)
        #expect(provider.makePageCalls == 1)
    }

    /// Quick Look: a fresh deck has no rendered slides in the (suite's own) cache: its page is missing for output.
    @Test func missingPagesUseForeignProvider() async throws {
        let deck = try OfficeFixtures.pptx(slides: ["Folie \(UUID().uuidString)"], name: "e.pptx", in: base)
        let word = try OfficeFixtures.docx(paragraphs: ["Bleibt"], name: "f.docx", in: base)
        // A deck whose slide is in the cache stays ticked.
        let cached = try OfficeFixtures.pptx(slides: ["Folie"], name: "g.pptx", in: base)
        let values = try cached.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        try slides.store([try ImageFixtures.render(text: "Folie", size: CGSize(width: 160, height: 90))],
                         for: SlideCacheKey(url: cached, fileSize: Int64(values.fileSize ?? 0),
                                            modifiedAt: values.contentModificationDate ?? .distantPast))
        let model = model(FakeEnvironment(), renderer: "quickLook")
        model.selection.toggle(PageRef(url: deck, pageIndex: 0))
        model.selection.toggle(PageRef(url: word, pageIndex: 0))
        model.selection.toggle(PageRef(url: cached, pageIndex: 0))

        model.removeMissingPagesFromSelection()
        await model.waitUntilIdle()
        #expect(Set(model.selection.ordered(documentOrder: [])) == [PageRef(url: word, pageIndex: 0), PageRef(url: cached, pageIndex: 0)])
    }

    /// „Fehlende Seiten entfernen“ with the own viewer (default): SlideKit has every slide of a readable deck without a
    /// layout or cache; a slide past the end and an unreadable deck are missing.
    @Test func missingPagesUnderSlideKit() async throws {
        let deck = try OfficeFixtures.pptx(slides: ["Folie \(UUID().uuidString)"], name: "s.pptx", in: base)
        let broken = base.appendingPathComponent("kaputt.pptx")
        try Data("kein zip".utf8).write(to: broken)
        let model = model(FakeEnvironment())
        let kept = PageRef(url: deck, pageIndex: 0)
        for ref in [kept, PageRef(url: deck, pageIndex: 1), PageRef(url: broken, pageIndex: 0)] { model.selection.toggle(ref) }

        model.removeMissingPagesFromSelection()
        await model.waitUntilIdle()
        #expect(model.selection.ordered(documentOrder: []) == [kept])
    }

    /// Saving with the own viewer: the slide is SlideKit's vector page of the slide size (same renderer as the tile).
    @Test func savesSlideKitSlide() async throws {
        let deck = try OfficeFixtures.pptx(slides: ["Angebot Wasserwerk"], name: "v.pptx", in: base)
        let env = FakeEnvironment()
        env.saveURL = base.appendingPathComponent("Folie.pdf")
        let model = model(env)
        model.selection.toggle(PageRef(url: deck, pageIndex: 0))
        model.saveSelection()
        await model.waitUntilIdle()
        #expect(model.alertMessage == nil)
        let page = try #require(PDFDocument(url: env.saveURL!)?.page(at: 0))
        #expect(page.bounds(for: .mediaBox).size == CGSize(width: 720, height: 540))
        #expect(page.string?.contains("Angebot Wasserwerk") == true)
    }

    @Test func doubleClickOpensOfficeWithDefaultApp() throws {
        let env = FakeEnvironment()
        let model = model(env)
        let docx = base.appendingPathComponent("g.docx"), pdf = base.appendingPathComponent("h.pdf")

        model.openInPreview(PageRef(url: docx, pageIndex: 0))
        model.openInPreview(PageRef(url: pdf, pageIndex: 0))
        #expect(env.openedWithDefaultApp == [docx])
        #expect(env.opened == [pdf])
    }
}
