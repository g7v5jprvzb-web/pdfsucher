import CoreGraphics
import Foundation
import IndexKit
import OCRKit
import SearchKit
import Testing
import TestSupport
import UniformTypeIdentifiers

/// Spec 1.2 §10: the whole chain with real Vision — files on disk → Indexer (phase 1 + 2 with
/// `VisionOCRSource`) → IndexStore → SearchService.
@Suite("OCR end to end")
struct EndToEndOCRTests {
    @Test func mixedSourcesAreSearchable() async throws {
        let base = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Quelle", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Fotos"), withIntermediateDirectories: true)

        try PDFFixtures.makePDF(at: root.appendingPathComponent("text.pdf"), pages: ["Der Vertrag mit Herrn Müller gilt ab heute."])
        let scanPage = try OCRFixtures.textImage(["Prüfungsergebnis zum Vertrag", "Seite zwei des Scans"],
                                                 size: CGSize(width: 1240, height: 1754), fontSize: 48).image
        try OCRFixtures.makeScanPDF(at: root.appendingPathComponent("scan.pdf"), images: [scanPage])
        try OCRFixtures.makeMixedPDF(at: root.appendingPathComponent("gemischt.pdf"), text: "Anlage zum Vertrag mit genug Text hier",
                                     image: try OCRFixtures.textImage(["Kündigungsfrist drei Monate"], size: CGSize(width: 1240, height: 1754), fontSize: 48).image)
        let (photo, photoRects) = try OCRFixtures.textImage(["Überweisung zum Vertrag", "Betrag 120 Euro"])
        try OCRFixtures.write(photo, to: root.appendingPathComponent("Fotos/beleg.jpg"), type: .jpeg)
        try OCRFixtures.write(try OCRFixtures.textImage(["Quittung Vertrag"]).image, to: root.appendingPathComponent("Fotos/quittung.heic"), type: .heic)

        let store = try IndexStore(fileURL: base.appendingPathComponent("index.sqlite"), root: root)
        let report = try await Indexer(root: root, store: store, ocr: VisionOCRSource()).update { _ in }
        #expect(report.added == 5 && report.failed.isEmpty)
        #expect(report.ocr.recognized == 4 && report.ocr.failed.isEmpty && report.ocr.deferred == 0, "\(report.ocr)")
        #expect(try store.pendingOCRJobs().isEmpty)

        let service = SearchService(index: store, root: root)
        let all = ["Fotos/beleg.jpg", "Fotos/quittung.heic", "gemischt.pdf", "scan.pdf", "text.pdf"]
        for sort in [SortMode.matchCount, .relevance, .modifiedDate, .fileName, .folder] {
            let hits = try service.search(QueryParser.parse("Vertrag", partialWords: false), sort: sort)
            #expect(Set(hits.map(\.relativePath)) == Set(all), "\(sort): \(hits.map(\.relativePath))")
        }
        #expect(try service.search(QueryParser.parse("Prüfungsergebnis", partialWords: false), sort: .fileName)
            .map(\.relativePath) == ["scan.pdf"])
        let mixed = try service.search(QueryParser.parse("Kündigungsfrist", partialWords: false), sort: .fileName)
        #expect(mixed.map(\.relativePath) == ["gemischt.pdf"])
        #expect(mixed.first?.pageHits.map(\.pageIndex) == [1])
        #expect(try service.search(QueryParser.parse("*weisu*", partialWords: false), sort: .fileName)
            .map(\.relativePath) == ["Fotos/beleg.jpg"])

        // Word boxes of the photo lie over the rendered word (10 %, spec §10).
        let beleg = try #require(try store.documents().first { $0.relativePath == "Fotos/beleg.jpg" })
        let text = try #require(try store.allPages().first { $0.docId == beleg.id }?.text) as NSString
        let word = try #require(try store.ocrWords(docId: beleg.id, pageIndex: 0).first { text.substring(with: $0.range) == "Überweisung" })
        let expected = try #require(photoRects["Überweisung"])
        #expect(abs(word.box.midX - expected.midX) < 0.1 && abs(word.box.midY - expected.midY) < 0.1, "\(word.box) vs \(expected)")

        // Second run: nothing is recognized again.
        let again = try await Indexer(root: root, store: store, ocr: VisionOCRSource()).update { _ in }
        #expect(again.unchanged == 5 && again.ocr == OCRReport())
    }
}
