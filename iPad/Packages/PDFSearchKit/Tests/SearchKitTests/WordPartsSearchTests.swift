import Foundation
import IndexKit
import SearchKit
import Testing
import TestSupport

/// 1.3.12: an infix search while the trigram index is incomplete finds exactly what it finds once it is complete.
@Suite("Wortteil-Suche bei unvollständigem Index")
struct WordPartsSearchTests {
    let root = URL(fileURLWithPath: "/tmp/pdfs", isDirectory: true)

    func file(_ path: String) -> ScannedFile {
        ScannedFile(relativePath: path, url: root.appendingPathComponent(path), fileSize: 1, modifiedAt: Date(timeIntervalSince1970: 0))
    }

    func found(_ service: SearchService, _ text: String, batchSize: Int = 3_000) throws -> [String: [Int]] {
        var early: [DocumentHit]?
        let hits = try service.search(QueryParser.parse(text, partialWords: false), sort: .fileName, batchSize: batchSize,
                                      onPartial: { early = $0 })
        // Early rows are a subset of the final result, with the same pages.
        let final = Dictionary(uniqueKeysWithValues: hits.map { ($0.relativePath, $0.pageHits.map(\.pageIndex)) })
        for hit in early ?? [] { #expect(final[hit.relativePath] == hit.pageHits.map(\.pageIndex)) }
        return final
    }

    @Test func infixSearchHasNoGapsWhileTheWordPartsIndexIsBuilt() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try IndexStore(fileURL: dir.appendingPathComponent("index.sqlite"), root: root)
        try store.upsert(file("alt.pdf"), pages: [PageText(pageIndex: 0, text: "Mietvertrag"), PageText(pageIndex: 1, text: "Anlage")], status: .ok)
        try store.fillTrigramIndex(maxPages: 1_000)
        for d in 0..<6 {
            try store.upsert(file("neu\(d).pdf"), pages: [PageText(pageIndex: 0, text: "Seite ohne Treffer"),
                                                         PageText(pageIndex: 1, text: d.isMultiple(of: 2) ? "Vertragsende \(d)" : "Kaufpreis")],
                             status: .ok)
        }
        #expect(try store.trigramProgress().pending == 12)
        let service = SearchService(index: store, root: root)
        let expected = ["alt.pdf": [0], "neu0.pdf": [1], "neu2.pdf": [1], "neu4.pdf": [1]]
        for batchSize in [1, 3, 3_000] {
            #expect(try found(service, "*trag*", batchSize: batchSize) == expected)
        }
        #expect(try found(service, "*ufpre*").keys.sorted() == ["neu1.pdf", "neu3.pdf", "neu5.pdf"])
        #expect(try found(service, "vertrag*").keys.sorted() == ["neu0.pdf", "neu2.pdf", "neu4.pdf"], "prefix: word index, at once")
        try store.fillTrigramIndex(maxPages: 2)                               // part of it
        #expect(try found(service, "*trag*", batchSize: 1) == expected)
        while try store.fillTrigramIndex(maxPages: 1_000) > 0 {}
        #expect(try found(service, "*trag*", batchSize: 1) == expected)
    }
}
