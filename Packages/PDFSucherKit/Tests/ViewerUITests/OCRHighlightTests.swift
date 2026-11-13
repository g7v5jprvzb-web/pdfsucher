import AppKit
import Foundation
import IndexKit
import OCRKit
import OutputKit
import PDFKit
import SearchKit
import Testing
import TestSupport
@testable import ViewerUI

/// Spec 1.2 §5: highlights on scans and images — normalized word boxes into PDF page space, word slices,
/// the 1.1 marks (colour, enlarged on small tiles) on OCR pages.
@Suite("OCR highlights")
struct OCRHighlightTests {
    /// Makes a one-page PDF with the given crop box and /Rotate.
    private func page(crop: CGRect, rotation: Int) throws -> PDFPage {
        let url = try PDFFixtures.tempDirectory().appendingPathComponent("r\(rotation).pdf")
        try PDFFixtures.makePDF(at: url, pages: ["x"])
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        page.setBounds(CGRect(x: 0, y: 0, width: 700, height: 900), for: .mediaBox)
        page.setBounds(crop, for: .cropBox)
        page.rotation = rotation
        return page
    }

    /// A normalized top-left box mapped to page space and back through PDFKit's own display transform.
    @Test(arguments: [0, 90, 180, 270])
    func scanBoxesMapThroughCropBoxAndRotation(rotation: Int) throws {
        let crop = CGRect(x: 40, y: 60, width: 500, height: 700)
        let p = try page(crop: crop, rotation: rotation)
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)
        let rect = OCRMapping.pageRect(box, cropBox: crop, rotation: rotation)
        // PDFKit: page space → display space (origin bottom left of the rotated crop box).
        let display = rect.applying(p.transform(for: .cropBox))
        let shown = ZoomMath.rotatedSize(crop.size, rotation: rotation)
        let back = CGRect(x: display.minX / shown.width, y: 1 - display.maxY / shown.height,
                          width: display.width / shown.width, height: display.height / shown.height)
        #expect(abs(back.minX - box.minX) < 0.001, "\(rotation): \(back)")
        #expect(abs(back.minY - box.minY) < 0.001, "\(rotation): \(back)")
        #expect(abs(back.width - box.width) < 0.001, "\(rotation): \(back)")
        #expect(abs(back.height - box.height) < 0.001, "\(rotation): \(back)")
    }

    @Test func imageBoxesFlipToBottomLeft() {
        let r = OCRMapping.imageRect(CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.2), imageSize: CGSize(width: 400, height: 200))
        #expect(r == CGRect(x: 100, y: 140, width: 200, height: 40))
    }

    /// `*trag*` inside the recognized word „Vertrag“ marks only the letters, proportionally.
    @Test func wildcardMarksSliceOfWord() {
        let ocr = OCRPageText(text: "Der Vertrag", words: [OCRWord(range: NSRange(location: 0, length: 3), box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)),
                                                         OCRWord(range: NSRange(location: 4, length: 7), box: CGRect(x: 0.35, y: 0.1, width: 0.35, height: 0.1))])
        let ranges: HighlightRanges = { text in text.range(of: "trag").map { [$0] } ?? [] }
        let boxes = OCRHighlights.normalizedBoxes(ocr, highlightRanges: ranges)
        #expect(boxes.count == 1)
        #expect(abs(boxes[0].minX - (0.35 + 0.35 * 3 / 7)) < 0.0001)
        #expect(abs(boxes[0].width - 0.35 * 4 / 7) < 0.0001)
    }

    /// Real recognition of a scan: the thumbnail marks the word at its place (± 10 %).
    @Test(.timeLimit(.minutes(1))) func ocrThumbnailMarksWord() async throws {
        let dir = try PDFFixtures.tempDirectory()
        let (image, wordRects) = try OCRFixtures.textImage(["Vertrag gilt"], size: CGSize(width: 1654, height: 2339), fontSize: 120)
        let url = dir.appendingPathComponent("scan.pdf")
        try OCRFixtures.makeScanPDF(at: url, images: [image])
        let result = try VisionOCRSource().recognize(pageIndex: 0, of: url, kind: .pdf)
        let ocr = OCRPageText(text: result.text, words: result.words)
        let ranges: HighlightRanges = { text in text.range(of: "Vertrag").map { [$0] } ?? [] }
        let cache = ThumbnailCache(scale: 1)
        let size = CGSize(width: 400, height: 566)                // exact marks (≥ 280 pt)
        let thumb = try #require(await cache.thumbnail(for: PageRef(url: url, pageIndex: 0), size: size, highlightKey: "v",
                                                       highlightRanges: ranges, highlightColor: RGBA(r: 1, g: 0, b: 0, a: 1), ocr: ocr))
        var rect = CGRect(origin: .zero, size: size)
        let rep = NSBitmapImageRep(cgImage: try #require(thumb.cgImage(forProposedRect: &rect, context: nil, hints: nil)))
        var marked: [CGPoint] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.9, c.greenComponent < 0.75, abs(c.greenComponent - c.blueComponent) < 0.1 {
                    marked.append(CGPoint(x: CGFloat(x) / CGFloat(rep.pixelsWide), y: CGFloat(y) / CGFloat(rep.pixelsHigh)))
                }
            }
        }
        #expect(marked.count > 50)
        let expected = try #require(wordRects["Vertrag"]).insetBy(dx: -0.1, dy: -0.1)
        let inside = marked.filter { expected.contains($0) }.count
        #expect(Double(inside) / Double(max(marked.count, 1)) > 0.9, "\(inside) of \(marked.count) inside \(expected)")
    }

    /// The large preview marks OCR words with highlight annotations at the mapped place.
    @MainActor @Test func previewAnnotationsForOCRPage() throws {
        let crop = CGRect(x: 0, y: 0, width: 595, height: 842)
        let p = try page(crop: crop, rotation: 0)
        let ocr = OCRPageText(text: "Vertrag", words: [OCRWord(range: NSRange(location: 0, length: 7), box: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05))])
        let ranges: HighlightRanges = { text in [text.startIndex..<text.endIndex] }
        let annotations = PDFPageView.ocrAnnotations(on: p, ocr: ocr, highlightRanges: ranges, color: .yellow)
        #expect(annotations.count == 1)
        let b = try #require(annotations.first?.bounds)
        #expect(abs(b.minX - 59.5) < 0.5 && abs(b.maxY - 842 * 0.9) < 0.5)
    }

    // MARK: Review of Task 4

    /// Stepping from one OCR page to the next of the same scan: the marks belong to the new page.
    @MainActor @Test func previewKeyFollowsTheOCRPage() {
        let p0 = OCRPageText(text: "Vertrag", words: [OCRWord(range: NSRange(location: 0, length: 7), box: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05))])
        let p1 = OCRPageText(text: "Vertrag", words: [OCRWord(range: NSRange(location: 0, length: 7), box: CGRect(x: 0.5, y: 0.6, width: 0.3, height: 0.05))])
        let url = URL(fileURLWithPath: "/d/scan.pdf")
        let shown = DetailOCR(ref: PageRef(url: url, pageIndex: 0), text: p0)
        #expect(shown.text(for: PageRef(url: url, pageIndex: 0)) == p0)
        #expect(shown.text(for: PageRef(url: url, pageIndex: 1)) == nil)       // stale: not drawn on page 1
        #expect(PDFPageView.key(pageIndex: 1, highlightKey: "q", color: .yellow, ocr: DetailOCR(ref: PageRef(url: url, pageIndex: 1), text: p1))
                != PDFPageView.key(pageIndex: 1, highlightKey: "q", color: .yellow, ocr: nil))
    }

    /// A page recognized without words keeps the marks of its (short) text layer.
    @Test func ocrWithoutWordsFallsBackToTextLayer() {
        #expect(OCRHighlights.usable(OCRPageText(text: "kurz", words: [])) == nil)
        let ocr = OCRPageText(text: "x", words: [OCRWord(range: NSRange(location: 0, length: 1), box: .zero)])
        #expect(OCRHighlights.usable(ocr) == ocr)
    }
}
