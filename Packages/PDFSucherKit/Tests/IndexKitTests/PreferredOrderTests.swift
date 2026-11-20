import Foundation
@testable import IndexKit
import Testing
import TestSupport

/// 1.4.0 P2: work below the folder filter goes first.
@Suite("Vorrang nach Ordnerfilter")
struct PreferredOrderTests {
    @Test func preferredJobsComeFirstAndANewFilterAppliesToTheRest() {
        var order = PreferredOrder(["a/1", "b/1", "a/2", "c/1", "b/2", "c/2"], path: { $0 })
        #expect(order.next(preferring: []) == "a/1")
        #expect(order.next(preferring: ["b/"]) == "b/1")
        #expect(order.next(preferring: ["b/"]) == "b/2")
        #expect(order.next(preferring: ["c/"]) == "c/1")
        #expect(order.next(preferring: ["c/"]) == "c/2")
        #expect(order.next(preferring: []) == "a/2")
        #expect(order.next(preferring: []) == nil)
    }

    @Test func wordPartsGoFirstBelowThePreferredFolder() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        let store = try IndexStore(fileURL: dir.appendingPathComponent("index.sqlite"), root: root)
        for path in ["a.pdf", "Ä/b.pdf", "Ä/c.pdf", "z.pdf"] {
            try store.upsert(ScannedFile(relativePath: path, url: root.appendingPathComponent(path), fileSize: 1, modifiedAt: .distantPast),
                             pages: [PageText(pageIndex: 0, text: "Text"), PageText(pageIndex: 1, text: "mehr")], status: .ok)
        }
        #expect(try store.fillTrigramIndex(maxPages: 2, preferring: ["Ä/"]) == 2)
        let raw = try SQLiteConnection(path: dir.appendingPathComponent("index.sqlite").path)
        let waiting = try raw.query("""
            SELECT DISTINCT d.path AS path FROM trigram_pending t JOIN page_text p ON p.id = t.page_id JOIN documents d ON d.id = p.doc_id ORDER BY d.path
            """, []).map { $0["path"] }
        #expect(waiting == [.text("a.pdf"), .text("z.pdf"), .text("Ä/c.pdf")])
        #expect(try store.fillTrigramIndex(maxPages: 10, preferring: ["Ä/"]) == 2)
        #expect(try store.fillTrigramIndex(maxPages: 10, preferring: ["Ä/"]) == 4, "nothing left below: the rest in order")
        #expect(try store.trigramProgress().pending == 0)
    }
}

@Suite("OCR-Parallelität nach Kernen")
struct OCRParallelismTests {
    /// 1.5.0: one per performance core, 2 to 8 (M2 Pro: 6 or 8).
    @Test func onePerPerformanceCoreTwoToEight() {
        #expect(Indexer.parallelism(performanceCores: 1) == 2)
        #expect(Indexer.parallelism(performanceCores: 4) == 4)
        #expect(Indexer.parallelism(performanceCores: 6) == 6)
        #expect(Indexer.parallelism(performanceCores: 8) == 8)
        #expect(Indexer.parallelism(performanceCores: 12) == 8)
        #expect(Indexer.performanceCores > 0)
    }
}
