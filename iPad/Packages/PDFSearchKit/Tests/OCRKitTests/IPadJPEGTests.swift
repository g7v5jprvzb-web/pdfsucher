import CoreGraphics
import Foundation
import IndexKit
import OCRKit
import SearchKit
import Testing
import TestSupport

/// iPad (PDF Search): only PDF and JPEG are indexed; JPEG text comes from Vision and is searchable
/// with boxes for the preview frames.
@Suite("iPad: PDF und JPEG")
struct IPadJPEGTests {
    private let scanner = FolderScanner(includeImages: true, imageExtensions: SupportedSourceTypes.iPadImageExtensions)

    @Test func scannerListsOnlyPDFAndJPEG() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.PNG", "b.jpeg", "c.heic", "d.dng", "e.JPG", "x.pdf", "sub/f.jpg", "w.docx"] {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let files = try scanner.scan(root: root)
        #expect(files.map(\.relativePath) == ["b.jpeg", "e.JPG", "sub/f.jpg", "x.pdf"])
    }

    @Test func scopedScannerKeepsTheJPEGLimit() throws {
        let root = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sub.appendingPathComponent("a.png"))
        try Data("x".utf8).write(to: sub.appendingPathComponent("b.jpg"))
        let files = try #require(scanner.scoped(depth: 1)).scan(root: sub)
        #expect(files.map(\.relativePath) == ["b.jpg"])
    }

    @Test func jpegTextIsFoundWithBoxes() async throws {
        let base = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Quelle", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PDFFixtures.makePDF(at: root.appendingPathComponent("brief.pdf"), pages: ["Die Rechnung liegt bei."])
        try OCRFixtures.write(try OCRFixtures.textImage(["Kassenbon", "Summe 4,70 EUR"]).image,
                              to: root.appendingPathComponent("bon.jpg"), type: .jpeg)
        try OCRFixtures.write(try OCRFixtures.textImage(["Summe auf PNG"]).image,
                              to: root.appendingPathComponent("ignoriert.png"), type: .png)

        let store = try IndexStore(fileURL: base.appendingPathComponent("index.sqlite"), root: root)
        let report = try await Indexer(root: root, store: store, scanner: scanner, ocr: VisionOCRSource()).update { _ in }
        #expect(report.added == 2 && report.failed.isEmpty)
        #expect(report.ocr.recognized == 1, "\(report.ocr)")

        let query = QueryParser.parse("Summe", partialWords: false)
        let hits = try SearchService(index: store, root: root).search(query, sort: .matchCount, searchNames: true)
        #expect(hits.map(\.relativePath) == ["bon.jpg"])
        #expect(hits.first?.kind == .image)

        let page = try #require(try store.ocrPage(relativePath: "bon.jpg", pageIndex: 0))
        let ranges = try #require(PageMatcher(query).ranges(in: page.text))
        let boxes = HighlightBoxesProbe.rects(ranges.map { NSRange($0, in: page.text) }, page.words)
        #expect(boxes.count == 1)
        #expect(boxes.allSatisfy { $0.minX >= 0 && $0.maxX <= 1 && $0.minY >= 0 && $0.maxY <= 1 && $0.width > 0 })
    }
}

/// Word boxes covering ranges (the same rule as MediaKit's `HighlightBoxes`, which this target does not link).
enum HighlightBoxesProbe {
    static func rects(_ ranges: [NSRange], _ words: [OCRWord]) -> [CGRect] {
        ranges.flatMap { range in words.filter { NSIntersectionRange(range, $0.range).length > 0 }.map(\.box) }
    }
}
