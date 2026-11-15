import AppKit
import Foundation
import IndexKit
import PDFKit
import SearchKit
import Synchronization
import Testing
import OutputKit
import TestSupport
@testable import ViewerUI

/// 1.3 Teil B Task 13: Word/PowerPoint tiles through the `ForeignPageProvider` (ViewerUI knows no OfficeKit).
@Suite("ThumbnailCache (Office)")
struct ThumbnailCacheForeignTests {
    /// A provider for `.docx`/`.pptx` whose one-page documents are blank pages of 200 × 283 pt.
    final class FakeProvider: ForeignPageProvider {
        struct State {
            var available = true
            var version = "fake:1"
            var maxPixels: [Int?] = []
            var documentCalls = 0
        }
        let state = Mutex(State())

        func handles(_ url: URL) -> Bool { ["docx", "pptx"].contains(url.pathExtension.lowercased()) }
        func pageCount(of url: URL) -> Int? { state.withLock { $0.available } ? 3 : nil }
        func makePage(_ ref: PageRef) throws -> PDFPage { throw OutputError.cannotOpen(ref.url) }
        func contentVersion(_ url: URL) -> String { state.withLock { $0.version } }
        func pageDocument(_ ref: PageRef, maxPixel: Int?) -> PDFDocument? {
            let available = state.withLock { s in
                s.documentCalls += 1
                s.maxPixels.append(maxPixel)
                return s.available
            }
            guard available, ref.pageIndex >= 0, ref.pageIndex < 3 else { return nil }
            return Self.blankDocument()
        }

        static func blankDocument() -> PDFDocument? {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 200, height: 283)
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

    private func tileFolderIsEmpty(_ disk: TileDiskCache, for url: URL) -> Bool {
        let folder = disk.folderURL(TileDiskCache.name(source: url.standardizedFileURL.path, parts: []).folder)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.filter { !$0.hasPrefix(".") }.isEmpty
    }

    @Test func officeTileFromForeignProvider() async throws {
        let provider = FakeProvider()
        let cache = ThumbnailCache(foreign: provider)
        let size = CGSize(width: 100, height: 141)
        let image = try #require(await cache.thumbnail(for: PageRef(url: try officeFile(), pageIndex: 2), size: size))
        #expect(image.size == size)
        let asked = provider.state.withLock { $0.maxPixels }
        #expect(asked.count == 1)
        let maxPixel = try #require(asked.first ?? nil)
        #expect(maxPixel > 0 && maxPixel <= 2048)
        // Huge tile: the hint stays capped.
        _ = await cache.thumbnail(for: PageRef(url: try officeFile("b.pptx"), pageIndex: 0), size: CGSize(width: 3000, height: 4242))
        #expect(provider.state.withLock { $0.maxPixels.last ?? nil } == 2048)
        // One-page documents are not pooled (like images).
        #expect(cache.cachedDocumentCount == 0)
        #expect(cache.documentOpenCount == 0)
    }

    @Test func officeTileNilWithoutPage() async throws {
        let provider = FakeProvider()
        provider.state.withLock { $0.available = false }
        let disk = TileDiskCache(directory: try PDFFixtures.tempDirectory().appendingPathComponent("Tiles"))
        let cache = ThumbnailCache(disk: disk, foreign: provider)
        let url = try officeFile()
        #expect(await cache.thumbnail(for: PageRef(url: url, pageIndex: 0), size: CGSize(width: 100, height: 141)) == nil)
        disk.flush()
        #expect(cache.cachedImageCount == 0)
        #expect(tileFolderIsEmpty(disk, for: url))
    }

    @Test func officeTileAppearsAfterLayoutWithoutRestart() async throws {
        let provider = FakeProvider()
        provider.state.withLock { $0.available = false }
        let cache = ThumbnailCache(foreign: provider)
        let ref = PageRef(url: try officeFile(), pageIndex: 0)
        let size = CGSize(width: 100, height: 141)
        #expect(await cache.thumbnail(for: ref, size: size) == nil)
        provider.state.withLock { $0.available = true }
        #expect(await cache.thumbnail(for: ref, size: size) != nil)
    }

    @Test func officeTileHighlightsFromOCRText() async throws {
        let provider = FakeProvider()
        let cache = ThumbnailCache(foreign: provider)
        let ref = PageRef(url: try officeFile(), pageIndex: 0)
        let size = CGSize(width: 400, height: 566)   // the page's aspect: no margin
        let box = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05)
        let ocr = OCRPageText(text: "Vertrag", words: [OCRWord(range: NSRange(location: 0, length: 7), box: box)])
        let ranges: HighlightRanges = { text in [text.startIndex..<text.endIndex] }
        let plain = try #require(await cache.thumbnail(for: ref, size: size))
        #expect(PixelProbe(plain).boundingBox(where: PixelProbe.isYellow) == nil)
        let marked = try #require(await cache.thumbnail(for: ref, size: size, highlightKey: "v", highlightRanges: ranges, ocr: ocr))
        let probe = PixelProbe(marked)
        let yellow = try #require(probe.boundingBox(where: PixelProbe.isYellow))
        let word = CGRect(x: box.minX * CGFloat(probe.width), y: box.minY * CGFloat(probe.height),
                          width: box.width * CGFloat(probe.width), height: box.height * CGFloat(probe.height))
        #expect(word.insetBy(dx: -4, dy: -4).contains(CGPoint(x: yellow.midX, y: yellow.midY)), "\(yellow) in \(word)")
        #expect(yellow.intersects(word))
    }

    @Test func officeTileKeyChangesWithContentVersion() async throws {
        let provider = FakeProvider()
        let disk = TileDiskCache(directory: try PDFFixtures.tempDirectory().appendingPathComponent("Tiles"))
        let cache = ThumbnailCache(disk: disk, foreign: provider)
        let ref = PageRef(url: try officeFile("deck.pptx"), pageIndex: 0)
        let size = CGSize(width: 100, height: 141)
        let first = try #require(await cache.thumbnail(for: ref, size: size))
        #expect(await cache.thumbnail(for: ref, size: size) === first)
        #expect(provider.state.withLock { $0.documentCalls } == 1)
        disk.flush()

        // Relaid out (renderer upgrade, slide cache rebuilt) without a file change: not the old tile.
        provider.state.withLock { $0.version = "fake:2" }
        let second = try #require(await cache.thumbnail(for: ref, size: size))
        #expect(second !== first)
        #expect(provider.state.withLock { $0.documentCalls } == 2)
        disk.flush()

        // Nor from disk in a new run with yet another version.
        provider.state.withLock { $0.version = "fake:3" }
        let fresh = ThumbnailCache(disk: disk, foreign: provider)
        #expect(await fresh.thumbnail(for: ref, size: size) != nil)
        #expect(provider.state.withLock { $0.documentCalls } == 3)
        disk.flush()
        // The same version again comes from disk without asking the provider.
        let again = ThumbnailCache(disk: disk, foreign: provider)
        #expect(await again.thumbnail(for: ref, size: size) != nil)
        #expect(provider.state.withLock { $0.documentCalls } == 3)
        // Plain tile is shown at once when it reappears.
        #expect(fresh.cachedImage(for: ref, size: size, highlighted: false) != nil)
    }

    @Test func pdfTilesUnchanged() async throws {
        let provider = FakeProvider()
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("doc.pdf")
        try PDFFixtures.makePDF(at: url, pages: ["Vertragsende 2024"])
        let ref = PageRef(url: url, pageIndex: 0)
        let size = CGSize(width: 200, height: 283)
        let cache = ThumbnailCache(foreign: provider)
        let image = try #require(await cache.thumbnail(for: ref, size: size))
        let plain = try #require(await ThumbnailCache().thumbnail(for: ref, size: size))
        #expect(image.tiffRepresentation == plain.tiffRepresentation)
        #expect(provider.state.withLock { $0.documentCalls } == 0)
        #expect(cache.cachedImage(for: ref, size: size, highlighted: false) === image)
        #expect(cache.documentOpenCount == 1)
    }
}
