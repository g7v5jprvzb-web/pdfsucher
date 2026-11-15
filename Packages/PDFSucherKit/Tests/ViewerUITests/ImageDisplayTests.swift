import AppKit
import Foundation
import OutputKit
import PDFKit
import SearchKit
import Testing
import TestSupport
@testable import ViewerUI

/// Spec 1.2 §5: images in tiles and in the large preview, symbol and badge.
@Suite("Images and OCR pages in the UI")
struct ImageDisplayTests {
    /// A photo stored sideways with EXIF orientation 6 is shown upright (taller than wide).
    @Test func imageThumbnailIsUpright() async throws {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("foto.jpg")
        try ImageFixtures.makeImage(at: url, text: "Hallo", size: CGSize(width: 800, height: 400), format: .jpeg, exifOrientation: 6)
        let document = try #require(ImageDocument.make(url, maxPixel: 1000))
        #expect(document.pageCount == 1)
        let bounds = try #require(document.page(at: 0)).bounds(for: .cropBox)
        #expect(bounds.height > bounds.width)
        let thumb = await ThumbnailCache(scale: 1).thumbnail(for: PageRef(url: url, pageIndex: 0), size: CGSize(width: 200, height: 283))
        #expect(thumb != nil)
    }

    @MainActor @Test func detailLoadsImageAsOnePagePDF() async throws {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("bild.png")
        try ImageFixtures.makeImage(at: url, text: "Vertrag", size: CGSize(width: 600, height: 300), format: .png)
        guard case .ready(let detail) = await DetailDocument.load(PageRef(url: url, pageIndex: 0)) else { Issue.record("not loaded"); return }
        #expect(detail.pdf.pageCount == 1)
        let broken = url.deletingLastPathComponent().appendingPathComponent("kaputt.png")
        try Data("x".utf8).write(to: broken)
        #expect(await DetailDocument.load(PageRef(url: broken, pageIndex: 0)) == .unavailable)
    }

    @Test func rowHeaderShowsImageSymbol() {
        let image = DocumentHit(url: URL(fileURLWithPath: "/d/a.png"), relativePath: "a.png", modifiedAt: .distantPast, pageHits: [],
                                totalMatches: 0, relevance: 0, sourceRoot: URL(fileURLWithPath: "/d"), pageCount: 1, kind: .image)
        let pdf = DocumentHit(url: URL(fileURLWithPath: "/d/a.pdf"), relativePath: "a.pdf", modifiedAt: .distantPast, pageHits: [],
                              totalMatches: 0, relevance: 0, sourceRoot: URL(fileURLWithPath: "/d"), pageCount: 1)
        #expect(ViewerText.rowSymbol(image) == "photo")
        #expect(ViewerText.rowSymbol(pdf) == nil)
    }

    @Test func ocrBadgeOnlyOnOCRPagesOfPDFs() {
        let ocr = OCRPageText(text: "x", words: [])
        #expect(ThumbnailTile.showsOCRBadge(kind: .pdf, ocr: ocr))
        #expect(!ThumbnailTile.showsOCRBadge(kind: .image, ocr: ocr))
        #expect(!ThumbnailTile.showsOCRBadge(kind: .pdf, ocr: nil))
        #expect(ViewerText.ocrBadge == "Texterkennung")
    }

    /// Review of Task 5: image tiles keep no decoded image document around (memory); they are decoded at
    /// the tile's size.
    @Test func imageTilesKeepNoDocument() async throws {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("gross.png")
        try ImageFixtures.makeImage(at: url, text: "Hallo", size: CGSize(width: 3000, height: 2000), format: .png)
        let cache = ThumbnailCache(scale: 1)
        let thumb = await cache.thumbnail(for: PageRef(url: url, pageIndex: 0), size: CGSize(width: 200, height: 133))
        #expect(thumb != nil)
        #expect(cache.cachedDocumentCount == 0)
    }
}
