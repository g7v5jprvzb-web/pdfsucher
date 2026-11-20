import Testing
import Foundation
import PDFKit
import IndexKit
import SearchKit
import TestSupport

/// Test-local PDFKit text source: the production `PDFKitTextSource` belongs to Phase 1
/// and is a stub on this branch.
private struct PDFKitPageStrings: TextSource {
    struct Unreadable: Error {}
    func pages(of url: URL) throws -> [PageText] {
        guard let doc = PDFDocument(url: url) else { throw Unreadable() }
        return (0..<doc.pageCount).map { PageText(pageIndex: $0, text: doc.page(at: $0)?.string ?? "") }
    }
}

/// Counts how often the text is read.
private final class CountingSource: TextSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _reads = 0
    var reads: Int { lock.withLock { _reads } }
    func pages(of url: URL) throws -> [PageText] {
        lock.withLock { _reads += 1 }
        return [PageText(pageIndex: 0, text: "Vertrag"), PageText(pageIndex: 1, text: "Auftrag")]
    }
}

private struct FixedPages: TextSource {
    let texts: [String]
    func pages(of url: URL) throws -> [PageText] {
        texts.enumerated().map { PageText(pageIndex: $0.offset, text: $0.element) }
    }
}

@Suite("SingleDocumentSearch")
struct SingleDocumentSearchTests {
    @Test func singlePdfFindsAllPages() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("vertrag.pdf")
        // plan: term on pages 1, 3 and 4 of 5 → indices 0, 2, 3
        try PDFFixtures.makePDF(at: url, pages: [
            "Der Vertrag gilt", "nichts hier", "Vertrag und Vertrag", "Vertrag", "Ende",
        ])
        let hit = try SingleDocumentSearch(source: PDFKitPageStrings())
            .search(url: url, query: QueryParser.parse("vertrag", partialWords: false))
        let h = try #require(hit)
        #expect(h.pageHits.map(\.pageIndex) == [0, 2, 3])
        #expect(h.pageHits.map(\.matchCount) == [1, 2, 1])
        #expect(h.totalMatches == 4)
        #expect(h.relevance == 4)
        #expect(h.url == url)
        #expect(h.relativePath == "vertrag.pdf")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(h.modifiedAt == attributes[.modificationDate] as? Date)
    }

    @Test func noMatchOrEmptyQueryGivesNil() throws {
        let url = URL(fileURLWithPath: "/nonexistent/x.pdf")
        let search = SingleDocumentSearch(source: FixedPages(texts: ["Auftrag"]))
        #expect(try search.search(url: url, query: QueryParser.parse("Vertrag", partialWords: false)) == nil)
        #expect(try search.search(url: url, query: QueryParser.parse("  ", partialWords: false)) == nil)
    }

    @Test func usesTheSameRulesAsTheIndexSearch() throws {
        let url = URL(fileURLWithPath: "/nonexistent/x.pdf")
        let search = SingleDocumentSearch(source: FixedPages(texts: ["Vertragsende", "Auftrag", "Endergebnis"]))
        #expect(try search.search(url: url, query: QueryParser.parse("*ende", partialWords: false))?.pageHits.map(\.pageIndex) == [0])
        #expect(try search.search(url: url, query: QueryParser.parse("trag", partialWords: true))?.pageHits.map(\.pageIndex) == [0, 1])
    }

    @Test func sourceErrorsPropagate() {
        let search = SingleDocumentSearch(source: PDFKitPageStrings())
        #expect(throws: (any Error).self) {
            try search.search(url: URL(fileURLWithPath: "/nonexistent/x.pdf"),
                              query: QueryParser.parse("a", partialWords: false))
        }
    }

    @Test func pagesAreReadOnceWhileTheFileIsUnchanged() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("x.pdf")
        try Data("x".utf8).write(to: url)
        let source = CountingSource()
        let search = SingleDocumentSearch(source: source)
        _ = try search.search(url: url, query: QueryParser.parse("Vertrag", partialWords: false))
        _ = try search.search(url: url, query: QueryParser.parse("Vertr*", partialWords: false))
        _ = try search.search(url: url, query: QueryParser.parse("*trag*", partialWords: false))
        #expect(source.reads == 1)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: url.path)
        _ = try search.search(url: url, query: QueryParser.parse("Vertrag", partialWords: false))
        #expect(source.reads == 2)
    }

    @Test func scannedPdfWithoutTextIsReportedAsSuch() {
        let url = URL(fileURLWithPath: "/nonexistent/scan.pdf")
        let search = SingleDocumentSearch(source: FixedPages(texts: ["", " \n ", ""]))
        #expect(throws: SingleDocumentSearchError.noText(url)) {
            try search.search(url: url, query: QueryParser.parse("Vertrag", partialWords: false))
        }
    }

    @Test func cancelledSearchStops() async {
        let search = SingleDocumentSearch(source: FixedPages(texts: Array(repeating: "Vertrag", count: 100)))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try search.search(url: URL(fileURLWithPath: "/nonexistent/x.pdf"),
                                     query: QueryParser.parse("Vertrag", partialWords: false))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
