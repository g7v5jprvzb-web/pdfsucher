// Spec 1.2 §9: throughput of the text recognition (measure, not assert).
// PDFSUCHER_PERF=1 scripts/test.sh --filter perfOCRThroughput
import CoreGraphics
import Foundation
import IndexKit
import OCRKit
import Testing
import TestSupport
import UniformTypeIdentifiers

@Suite("OCR throughput", .enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_PERF"] == "1"))
struct OCRThroughputTests {
    static let words = ["Vertrag", "Rechnung", "Kündigung", "Prüfung", "Ergebnis", "Mieter", "Vermieter", "Zahlung",
                        "Betrag", "Monate", "schriftlich", "gemäß", "Anlage", "Übergabe", "Wohnung", "Schlüssel",
                        "Frist", "beträgt", "drei", "zum", "Ende", "des", "Quartals", "die", "der", "und", "mit",
                        "Herrn", "Müller", "Größe", "Straße", "Datum", "Unterschrift", "Euro", "Steuer", "Nummer"]

    static func lines(_ count: Int, wordsPerLine: Int, rng: inout SeededGenerator) -> [String] {
        (0..<count).map { _ in (0..<wordsPerLine).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ") }
    }

    /// Light-grey blotches over a photo-sized page, so it is not a clean rendering.
    static func photo(_ lines: [String], rng: inout SeededGenerator) throws -> CGImage {
        let size = CGSize(width: 3024, height: 4032)
        let (clean, _) = try OCRFixtures.textImage(lines, size: size, fontSize: 90)
        let context = try #require(CGContext(data: nil, width: 3024, height: 4032, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(clean, in: CGRect(origin: .zero, size: size))
        for _ in 0..<400 {
            let g = Double.random(in: 0.75...0.95, using: &rng)
            context.setFillColor(CGColor(red: g, green: g, blue: g * 0.97, alpha: 0.35))
            context.fillEllipse(in: CGRect(x: .random(in: 0...3000, using: &rng), y: .random(in: 0...4000, using: &rng),
                                           width: .random(in: 5...60, using: &rng), height: .random(in: 5...60, using: &rng)))
        }
        return try #require(context.makeImage())
    }

    struct Measurement { let name: String; let pages: Int; let seconds: Double; let markerHits: Int }

    static func run(root: URL, name: String, pages: Int) async throws -> Measurement {
        let store = try IndexStore(fileURL: root.deletingLastPathComponent().appendingPathComponent("\(name).sqlite"), root: root)
        let phase1 = try await Indexer(root: root, store: store, ocr: VisionOCRSource(),
                                       ocrSettings: OCRSettings(recognizeText: false, includeImages: true)).update { _ in }
        #expect(phase1.added > 0)
        let start = ContinuousClock.now
        let report = try await Indexer(root: root, store: store, ocr: VisionOCRSource()).recognizePending { _ in }
        let elapsed = ContinuousClock.now - start
        #expect(report.failed.isEmpty && report.deferred == 0)
        let hits = try store.match("Markierungswort", in: .words).count
        return Measurement(name: name, pages: pages,
                           seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                           markerHits: hits)
    }

    @Test(.timeLimit(.minutes(30)))
    func perfOCRThroughput() async throws {
        let base = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        var rng = SeededGenerator(seed: 42)

        // 100 scan pages: 10 PDFs × 10 A4 pages at 300 dpi (2480 × 3508 px), ~200 words each.
        let scans = base.appendingPathComponent("Scans", isDirectory: true)
        try FileManager.default.createDirectory(at: scans, withIntermediateDirectories: true)
        let genStart = ContinuousClock.now
        for file in 0..<10 {
            var images: [CGImage] = []
            for _ in 0..<10 {
                var text = Self.lines(28, wordsPerLine: 7, rng: &rng)
                text[3] = "Markierungswort " + text[3]
                images.append(try OCRFixtures.textImage(text, size: CGSize(width: 2480, height: 3508), fontSize: 46).image)
            }
            try OCRFixtures.makeScanPDF(at: scans.appendingPathComponent("scan\(file).pdf"), images: images)
        }
        // 100 photos: 3024 × 4032 JPEG (12 MP phone size), ~70 words plus blotches.
        let photos = base.appendingPathComponent("Fotos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        for i in 0..<100 {
            var text = Self.lines(14, wordsPerLine: 5, rng: &rng)
            text[1] = "Markierungswort " + text[1]
            try OCRFixtures.write(try Self.photo(text, rng: &rng), to: photos.appendingPathComponent("foto\(i).jpg"), type: .jpeg)
        }
        print("OCR perf: corpus generated in \(ContinuousClock.now - genStart)")

        var rows = ["| Korpus | Seiten | Zeit | Seiten/Minute | Markierungswort gefunden |", "|---|---|---|---|---|"]
        for (dir, name) in [(scans, "Scan-Seiten (A4, 300 dpi)"), (photos, "Fotos (3024 × 4032 JPEG)")] {
            let m = try await Self.run(root: dir, name: dir.lastPathComponent, pages: 100)
            rows.append(String(format: "| %@ | %d | %.1f s | %.0f | %d / 100 |", name, m.pages, m.seconds, Double(m.pages) / m.seconds * 60, m.markerHits))
        }
        print(rows.joined(separator: "\n"))
    }
}
