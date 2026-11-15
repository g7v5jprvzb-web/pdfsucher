import AppKit
import Foundation
import IndexKit
import OutputKit
import PDFKit
import Synchronization
import Testing
import TestSupport
@testable import ViewerUI

/// 1.3 Teil B Task 7: the large preview of Word/PowerPoint pages through the `ForeignPageProvider`.
@Suite("Office preview")
@MainActor
struct OfficePreviewTests {
    /// A provider for `.docx`/`.pptx` with 5 pages of 595 × 842 pt; records the threads and maxPixel it was asked on.
    final class FakeProvider: ForeignPageProvider {
        struct State {
            var available = true
            var onMain: [Bool] = []
            var maxPixels: [Int?] = []
        }
        let state = Mutex(State())

        func handles(_ url: URL) -> Bool { ["docx", "pptx"].contains(url.pathExtension.lowercased()) }
        func pageCount(of url: URL) -> Int? { 5 }
        func makePage(_ ref: PageRef) throws -> PDFPage { throw OutputError.cannotOpen(ref.url) }
        func pageDocument(_ ref: PageRef, maxPixel: Int?) -> PDFDocument? {
            let available = state.withLock { s in
                s.onMain.append(Thread.isMainThread)
                s.maxPixels.append(maxPixel)
                return s.available
            }
            guard available, ref.pageIndex >= 0, ref.pageIndex < 5 else { return nil }
            return Self.blankDocument()
        }

        static func blankDocument() -> PDFDocument? {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 595, height: 842)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
            ctx.beginPDFPage(nil)
            ctx.endPDFPage()
            ctx.closePDF()
            return PDFDocument(data: data as Data)
        }
    }

    private func officeFile(_ name: String = "a.docx") throws -> URL {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent(name)
        try Data("not really office".utf8).write(to: url)
        return url
    }

    @Test func officePreviewIsSinglePage() async throws {
        let provider = FakeProvider()
        let ref = PageRef(url: try officeFile(), pageIndex: 3)
        guard case .ready(let document) = await DetailDocument.load(ref, reusing: nil, foreign: provider) else {
            Issue.record("not loaded"); return
        }
        #expect(document.pdf.pageCount == 1)
        #expect(document.singlePage == 3)
        #expect(document.documentPageIndex(for: ref) == 0)
        let bounds = try #require(document.pdf.page(at: 0)).bounds(for: .mediaBox)
        #expect(bounds.width == 595 && bounds.height == 842)
        #expect(provider.state.withLock { $0.maxPixels } == [nil])
        // Same file, page and date: reused; another page: loaded anew.
        guard case .ready(let again) = await DetailDocument.load(ref, reusing: document, foreign: provider) else {
            Issue.record("not loaded"); return
        }
        #expect(again.pdf === document.pdf)
        let other = PageRef(url: ref.url, pageIndex: 1)
        guard case .ready(let second) = await DetailDocument.load(other, reusing: document, foreign: provider) else {
            Issue.record("not loaded"); return
        }
        #expect(second.pdf !== document.pdf)
        #expect(second.singlePage == 1)
    }

    @Test func officePreviewPreparingWhenNoPage() async throws {
        let provider = FakeProvider()
        provider.state.withLock { $0.available = false }
        let url = try officeFile("b.pptx")
        #expect(await DetailDocument.load(PageRef(url: url, pageIndex: 0), reusing: nil, foreign: provider) == .preparing)
        let gone = url.deletingLastPathComponent().appendingPathComponent("gone.docx")
        #expect(await DetailDocument.load(PageRef(url: gone, pageIndex: 0), reusing: nil, foreign: provider) == .missing)
        #expect(ViewerText.previewPreparing == "Vorschau wird vorbereitet …")
    }

    @Test func officePreviewLoadsOffMain() async throws {
        let provider = FakeProvider()
        _ = await DetailDocument.load(PageRef(url: try officeFile(), pageIndex: 0), reusing: nil, foreign: provider)
        let calls = provider.state.withLock { $0.onMain }
        #expect(calls == [false])
    }

    @Test func pdfPreviewUnchanged() async throws {
        let provider = FakeProvider()
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("d.pdf")
        try PDFFixtures.makePDF(at: url, pages: ["Eins", "Zwei"])
        let ref = PageRef(url: url, pageIndex: 1)
        guard case .ready(let document) = await DetailDocument.load(ref, reusing: nil, foreign: provider) else {
            Issue.record("not loaded"); return
        }
        #expect(document.singlePage == nil)
        #expect(document.pdf.pageCount == 2)
        #expect(document.documentPageIndex(for: ref) == 1)
        #expect(provider.state.withLock { $0.onMain }.isEmpty)
    }

    @Test func officeOpenButtonLabel() {
        #expect(ViewerText.openOriginal(kind: .word) == "Original öffnen")
        #expect(ViewerText.openOriginal(kind: .powerpoint) == "Original öffnen")
        #expect(ViewerText.openOriginal(kind: .pdf) == "In Vorschau öffnen")
        #expect(ViewerText.openOriginal(kind: .image) == "In Vorschau öffnen")
    }

    // Review fixes: what restarts the preview task and what stays on screen meanwhile.

    @Test func layoutRevisionRetriesOnlyAPreparingOfficePage() {
        let url = URL(fileURLWithPath: "/d/a.pptx")
        let ready = DetailLoad.ready(DetailDocument(url: url, modifiedAt: nil, pdf: PDFDocument(), singlePage: 2))
        // Not laid out yet and nothing loading: layout progress tries again.
        #expect(PageDetailView.retriesOnLayout(load: .preparing, isForeign: true, loading: false))
        // Still loading or shown: layout progress must not cancel and restart the render.
        #expect(!PageDetailView.retriesOnLayout(load: nil, isForeign: true, loading: true))
        #expect(!PageDetailView.retriesOnLayout(load: ready, isForeign: true, loading: false))
        #expect(!PageDetailView.retriesOnLayout(load: .unavailable, isForeign: true, loading: false))
        // PDF and image pages never follow the layout revision.
        #expect(!PageDetailView.retriesOnLayout(load: .preparing, isForeign: false, loading: false))
    }

    /// Re-review: paging within a file being prepared (or a retry) keeps `.preparing` on screen while the new load
    /// runs; layout progress must not restart that load (the check after the load catches up instead).
    @Test func layoutRevisionDoesNotRestartALoadInFlight() {
        #expect(!PageDetailView.retriesOnLayout(load: .preparing, isForeign: true, loading: true))
    }

    @Test func reusableOnlyForSameFileAndPage() {
        let url = URL(fileURLWithPath: "/d/a.docx")
        let office = DetailDocument(url: url, modifiedAt: nil, pdf: PDFDocument(), singlePage: 2)
        #expect(PageDetailView.reusable(load: .ready(office), for: PageRef(url: url, pageIndex: 2)) == office)
        #expect(PageDetailView.reusable(load: .ready(office), for: PageRef(url: url, pageIndex: 3)) == nil)
        #expect(PageDetailView.reusable(load: .ready(office), for: PageRef(url: URL(fileURLWithPath: "/d/b.docx"), pageIndex: 2)) == nil)
        let pdfURL = URL(fileURLWithPath: "/d/a.pdf")
        let whole = DetailDocument(url: pdfURL, modifiedAt: nil, pdf: PDFDocument())
        #expect(PageDetailView.reusable(load: .ready(whole), for: PageRef(url: pdfURL, pageIndex: 7)) == whole)
        #expect(PageDetailView.reusable(load: .preparing, for: PageRef(url: url, pageIndex: 2)) == nil)
        #expect(PageDetailView.reusable(load: nil, for: PageRef(url: url, pageIndex: 2)) == nil)
    }

    @Test func preparingStaysWhilePagingInTheSameFile() {
        let url = URL(fileURLWithPath: "/d/a.pptx")
        #expect(PageDetailView.placeholder(load: .preparing, loadedURL: url, for: PageRef(url: url, pageIndex: 4)) == .preparing)
        #expect(PageDetailView.placeholder(load: .preparing, loadedURL: url,
                                           for: PageRef(url: URL(fileURLWithPath: "/d/b.pptx"), pageIndex: 0)) == nil)
        #expect(PageDetailView.placeholder(load: .missing, loadedURL: url, for: PageRef(url: url, pageIndex: 4)) == nil)
        #expect(PageDetailView.placeholder(load: nil, loadedURL: nil, for: PageRef(url: url, pageIndex: 4)) == nil)
    }
}
