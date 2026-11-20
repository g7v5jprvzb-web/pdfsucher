import Foundation
import IndexKit
import PDFKit
import SearchKit
import Testing
import TestSupport

/// Task 5.5: the SearchKit expectations of `searchEndToEnd`, but through the real chain —
/// generated PDFs on disk → `Indexer` with `PDFKitTextSource` → real `IndexStore` → `SearchService`.
@Suite("Integration with the real index")
struct IntegrationTests {
    let root: URL
    let indexURL: URL

    init() throws {
        let base = try PDFFixtures.tempDirectory()
        root = base.appendingPathComponent("PDFs", isDirectory: true)
        indexURL = base.appendingPathComponent("index.sqlite")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try PDFFixtures.makePDF(at: root.appendingPathComponent("a.pdf"),
                                pages: ["Der Vertrag gilt.", "nichts", "Vertragsende heute, Vertragsende morgen"])
        try PDFFixtures.makePDF(at: root.appendingPathComponent("sub/b.pdf"), pages: ["Vertragsende", "Mietvertrag"])
        try PDFFixtures.makePDF(at: root.appendingPathComponent("c.pdf"), pages: ["Auftrag erteilt", "Abend", "Wir haben Zeit"])
        try Data("%PDF-1.4 kaputt Vertrag".utf8).write(to: root.appendingPathComponent("kaputt.pdf"))
        try Self.makeLockedPDF(at: root.appendingPathComponent("gesperrt.pdf"), text: "Vertrag Vertragsende Auftrag")
    }

    static func makeLockedPDF(at url: URL, text: String) throws {
        let plain = url.deletingLastPathComponent().appendingPathComponent("plain-\(UUID().uuidString).pdf")
        try PDFFixtures.makePDF(at: plain, pages: [text])
        defer { try? FileManager.default.removeItem(at: plain) }
        let document = try #require(PDFDocument(url: plain))
        #expect(document.write(to: url, withOptions: [.userPasswordOption: "geheim", .ownerPasswordOption: "geheim"]))
    }

    private func indexed() async throws -> (IndexStore, IndexReport) {
        let store = try IndexStore(fileURL: indexURL, root: root)
        let report = try await Indexer(root: root, store: store).update { _ in }
        return (store, report)
    }

    private func search(_ input: String, partial: Bool = false, in store: IndexStore) throws -> [DocumentHit] {
        try SearchService(index: store, root: root).search(QueryParser.parse(input, partialWords: partial), sort: .fileName)
    }

    @Test func searchEndToEndRealStore() async throws {
        let (store, _) = try await indexed()

        let prefix = try search("Vertrag*", in: store)
        #expect(prefix.map(\.relativePath) == ["a.pdf", "sub/b.pdf"])
        #expect(prefix.first?.pageHits == [PageHit(pageIndex: 0, matchCount: 1), PageHit(pageIndex: 2, matchCount: 2)])
        #expect(prefix.first?.totalMatches == 3)
        #expect(prefix.last?.pageHits == [PageHit(pageIndex: 0, matchCount: 1)])
        #expect(prefix.last?.url == root.appendingPathComponent("sub/b.pdf"))
        #expect((prefix.first?.relevance ?? 0) > 0)

        let infix = try search("*trag*", in: store)
        #expect(Set(infix.map(\.relativePath)) == ["a.pdf", "sub/b.pdf", "c.pdf"])
        #expect(infix.first { $0.relativePath == "sub/b.pdf" }?.pageHits.map(\.pageIndex) == [0, 1])

        let word = try search("Vertrag", in: store)
        #expect(word.map(\.relativePath) == ["a.pdf"])
        #expect(word.first?.pageHits == [PageHit(pageIndex: 0, matchCount: 1)])

        #expect(try search("trag", in: store).isEmpty)
        #expect(try search("trag", partial: true, in: store).count == 3)
        let short = try search("*ab*", in: store)
        #expect(short.map(\.relativePath) == ["c.pdf"])
        #expect(short.first?.pageHits.map(\.pageIndex) == [1, 2])
        #expect(try search("*ende", in: store).map(\.relativePath) == ["a.pdf", "sub/b.pdf"])
    }

    @Test func textSourceErrorsRealPDFKit() async throws {
        let (store, report) = try await indexed()
        #expect(Set(report.failed) == ["kaputt.pdf", "gesperrt.pdf"])
        let status = Dictionary(uniqueKeysWithValues: try store.documents().map { ($0.relativePath, $0.status) })
        #expect(status["kaputt.pdf"] == .error)
        #expect(status["gesperrt.pdf"] == .error)
        #expect(status["a.pdf"] == .ok)
        // the search keeps working and never returns the unreadable files
        #expect(try search("Auftrag", in: store).map(\.relativePath) == ["c.pdf"])

        let single = SingleDocumentSearch(source: PDFKitTextSource())
        let query = QueryParser.parse("Vertrag", partialWords: false)
        let broken = root.appendingPathComponent("kaputt.pdf"), locked = root.appendingPathComponent("gesperrt.pdf")
        #expect(throws: TextSourceError.unreadable(broken)) { try single.search(url: broken, query: query) }
        #expect(throws: TextSourceError.locked(locked)) { try single.search(url: locked, query: query) }
    }
}
