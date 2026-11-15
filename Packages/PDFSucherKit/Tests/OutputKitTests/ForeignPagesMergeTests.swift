import Foundation
import PDFKit
import Testing
import TestSupport
@testable import OutputKit

/// 1.3 Office Task 8: pages of files a `ForeignPageProvider` handles (Word, PowerPoint) in merge, print and the
/// availability check. OutputKit knows no Office types; a fake provider stands in for `OfficeKit.OfficePages`.
@Suite("Foreign pages in merge and print")
struct ForeignPagesMergeTests {
    /// Handles `.fake` files: each is "laid out" as the pages of the PDF next to it (`<name>.fake.pdf`).
    struct FakeProvider: ForeignPageProvider {
        struct Broken: Error {}

        func handles(_ url: URL) -> Bool { url.pathExtension == "fake" }

        func pageCount(of url: URL) -> Int? { PDFDocument(url: backing(url))?.pageCount }

        func makePage(_ ref: PageRef) throws -> PDFPage {
            if ref.url.lastPathComponent.hasPrefix("broken") { throw Broken() }
            guard let page = PDFDocument(url: backing(ref.url))?.page(at: ref.pageIndex) else {
                throw OutputError.pageOutOfRange(ref)
            }
            return page
        }

        private func backing(_ url: URL) -> URL { url.appendingPathExtension("pdf") }
    }

    let dir: URL
    let pdf: URL
    let foreign: URL

    init() throws {
        dir = try PDFFixtures.tempDirectory()
        pdf = dir.appendingPathComponent("A.pdf")
        foreign = dir.appendingPathComponent("Folien.fake")
        try PDFFixtures.makePDF(at: pdf, pages: ["Alpha null", "Alpha eins"])
        try PDFFixtures.makePDF(at: foreign.appendingPathExtension("pdf"), pages: ["Fremd null", "Fremd eins"])
        try Data("x".utf8).write(to: foreign)
    }

    @Test func mergerUsesForeignProviderInOrder() throws {
        let doc = try Merger(foreign: FakeProvider()).makeDocument([
            PageRef(url: pdf, pageIndex: 0), PageRef(url: foreign, pageIndex: 1), PageRef(url: foreign, pageIndex: 0),
        ])
        #expect(doc.pageCount == 3)
        #expect(doc.page(at: 0)?.string?.contains("Alpha null") == true)
        #expect(doc.page(at: 1)?.string?.contains("Fremd eins") == true)
        #expect(doc.page(at: 2)?.string?.contains("Fremd null") == true)
    }

    @Test func writtenFileContainsForeignPages() throws {
        let out = dir.appendingPathComponent("Auswahl.pdf")
        try Merger(foreign: FakeProvider()).write([PageRef(url: foreign, pageIndex: 0), PageRef(url: pdf, pageIndex: 1)], to: out)
        let doc = try #require(PDFDocument(url: out))
        #expect(doc.pageCount == 2)
        #expect(doc.page(at: 0)?.string?.contains("Fremd null") == true)
    }

    @Test func printDocumentUsesForeignProvider() throws {
        let built = try PrintDocument.build([PageRef(url: foreign, pageIndex: 1)], foreign: FakeProvider())
        #expect(built.document.page(at: 0)?.string?.contains("Fremd eins") == true)
    }

    @Test func unavailableForeignPage() {
        let refs = [PageRef(url: foreign, pageIndex: 0), PageRef(url: foreign, pageIndex: 2),
                    PageRef(url: foreign, pageIndex: -1), PageRef(url: dir.appendingPathComponent("weg.fake"), pageIndex: 0),
                    PageRef(url: pdf, pageIndex: 1)]
        #expect(Merger.unavailable(refs, foreign: FakeProvider()) == [refs[1], refs[2], refs[3]])
    }

    @Test func foreignPageOutOfRangeThrows() {
        let ref = PageRef(url: foreign, pageIndex: 2)
        #expect(throws: OutputError.pageOutOfRange(ref)) { try Merger(foreign: FakeProvider()).makeDocument([ref]) }
    }

    @Test func unreadableForeignFileThrowsCannotOpen() throws {
        let missing = dir.appendingPathComponent("weg.fake")
        #expect(throws: OutputError.cannotOpen(missing)) {
            try Merger(foreign: FakeProvider()).makeDocument([PageRef(url: missing, pageIndex: 0)])
        }
        let broken = dir.appendingPathComponent("broken.fake")
        try PDFFixtures.makePDF(at: broken.appendingPathExtension("pdf"), pages: ["x"])
        #expect(throws: OutputError.cannotOpen(broken)) {
            try Merger(foreign: FakeProvider()).makeDocument([PageRef(url: broken, pageIndex: 0)])
        }
    }

    @Test func withoutProviderBehaviourIsUnchanged() {
        let ref = PageRef(url: foreign, pageIndex: 0)
        #expect(Merger.unavailable([ref]) == [ref])
        #expect(throws: OutputError.cannotOpen(foreign)) { try Merger().makeDocument([ref]) }
    }

    // MARK: Page documents (1.3 Teil B)

    @Test func defaultPageDocumentWrapsMakePage() throws {
        let provider = FakeProvider()
        let doc = try #require(provider.pageDocument(PageRef(url: foreign, pageIndex: 1), maxPixel: nil))
        #expect(doc.pageCount == 1)
        #expect(doc.page(at: 0)?.string?.contains("Fremd eins") == true)
        #expect(provider.pageDocument(PageRef(url: foreign, pageIndex: 1), maxPixel: 200)?.pageCount == 1)
        #expect(provider.pageDocument(PageRef(url: foreign, pageIndex: 5), maxPixel: nil) == nil)
        #expect(provider.pageDocument(PageRef(url: dir.appendingPathComponent("weg.fake"), pageIndex: 0), maxPixel: nil) == nil)
    }
}
