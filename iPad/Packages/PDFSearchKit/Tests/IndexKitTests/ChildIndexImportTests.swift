import CoreGraphics
import Foundation
@testable import IndexKit
import Synchronization
import Testing
import TestSupport

/// 1.4.0 P1: a parent folder's index takes over what the indexes of its subfolders hold, so phase 1 does not read
/// those files again.
@Suite("Kind-Indizes übernehmen")
struct ChildIndexImportTests {
    final class Counting: TextSource, Sendable {
        private let calls = Mutex<[String]>([])
        var read: [String] { calls.withLock { $0 } }
        func pages(of url: URL) throws -> [PageText] {
            calls.withLock { $0.append(url.lastPathComponent) }
            return try PDFKitTextSource().pages(of: url)
        }
    }

    struct Env {
        let base: URL, parent: URL, child: URL, indexes: URL
        func cleanup() { try? FileManager.default.removeItem(at: base) }
        func store(for folder: URL) throws -> IndexStore {
            try IndexStore(fileURL: indexes.appendingPathComponent(IndexStore.location(forFolder: folder).lastPathComponent), root: folder)
        }
    }

    func makeEnv() throws -> Env {
        let base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        let parent = base.appendingPathComponent("Akten", isDirectory: true)
        let child = parent.appendingPathComponent("Kunde Ä/2025", isDirectory: true)
        let indexes = base.appendingPathComponent("Indexes", isDirectory: true)
        for dir in [child, indexes] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try PDFFixtures.makePDF(at: child.appendingPathComponent("rechnung.pdf"), pages: ["Rechnung Vertragsende", "Seite zwei"])
        try PDFFixtures.makePDF(at: child.appendingPathComponent("brief.pdf"), pages: ["Brief"])
        try PDFFixtures.makePDF(at: parent.appendingPathComponent("oben.pdf"), pages: ["Oben"])
        return Env(base: base, parent: parent, child: child, indexes: indexes)
    }

    @Test func parentTakesOverTheChildsDocumentsAndPhaseOneSkipsThem() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let childStore = try env.store(for: env.child)
        _ = try await Indexer(root: env.child, store: childStore).update { _ in }
        // A recognized page with word boxes in the child.
        try childStore.upsert(ScannedFile(relativePath: "scan.png", url: env.child.appendingPathComponent("scan.png"), fileSize: 7,
                                          modifiedAt: Date(timeIntervalSince1970: 5)),
                              pages: [PageText(pageIndex: 0, text: "", needsOCR: true)], status: .noText)
        let job = try #require(try childStore.pendingOCRJobs().first { $0.relativePath == "scan.png" })
        let words = [OCRWord(range: NSRange(location: 0, length: 4), box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05))]
        #expect(try childStore.storeOCR(job, text: "Foto", words: words))

        let parentStore = try env.store(for: env.parent)
        let children = IndexStore.childIndexes(of: env.parent, in: env.indexes, excluding: parentStore.fileURL)
        #expect(children.map(\.folderPath) == [env.child.standardizedFileURL.path])
        let result = try parentStore.importChild(try #require(children.first))
        #expect(result.documents == 3 && result.pages == 4)
        let paths = try parentStore.documents().map(\.relativePath)
        #expect(paths == ["Kunde Ä/2025/brief.pdf", "Kunde Ä/2025/rechnung.pdf", "Kunde Ä/2025/scan.png"])
        let scan = try #require(try parentStore.documents().first { $0.relativePath.hasSuffix("scan.png") })
        #expect(try parentStore.ocrWords(docId: scan.id, pageIndex: 0) == words)
        #expect(try parentStore.match("Vertragsende", in: .words).count == 1)
        #expect(try parentStore.trigramProgress().pending == 3, "text pages wait for the trigram index; the OCR page is in it")
        // Once only.
        #expect(try parentStore.importChild(try #require(children.first)) == IndexStore.ImportResult())

        let source = Counting()
        let report = try await Indexer(root: env.parent, store: parentStore, source: source).update { _ in }
        #expect(source.read == ["oben.pdf"], "the child's PDFs are not read again")
        #expect(report.added == 1)
        #expect(report.unchanged == 2)
        #expect(report.removed == 1, "the image is not listed without OCR: it leaves, as it would have")
    }

    @Test func layoutsOfAnotherRendererAreNotTakenOver() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let childStore = try env.store(for: env.child)
        try childStore.batch { db in
            try db.run("INSERT INTO meta(key, value) VALUES ('layout.expected.word', 'textkit:3')", [])
            let id = try db.run("""
                INSERT INTO documents(path, file_size, modified_at, page_count, status, kind, renderer, layout_version)
                VALUES ('a.docx', 1, 0, 1, 'ok', 'word', 'textkit', 3)
                """, [])
            try db.run("INSERT INTO page_text(doc_id, page_index, text, source) VALUES (?, 0, 'Wordtext', 'layout')", [.int(id)])
        }
        // Same renderer expected: kept with its page.
        let same = try env.store(for: env.parent)
        try same.batch { db in try db.run("INSERT INTO meta(key, value) VALUES ('layout.expected.word', 'textkit:3')", []) }
        let child = try #require(IndexStore.childIndexes(of: env.parent, in: env.indexes, excluding: same.fileURL).first)
        #expect(try same.importChild(child).pages == 1)
        #expect(try same.match("Wordtext", in: .words).count == 1)
        // Another renderer expected: no pages, waiting for layout.
        let otherURL = env.indexes.appendingPathComponent("other.sqlite")
        let other = try IndexStore(fileURL: otherURL, root: env.parent)
        try other.batch { db in try db.run("INSERT INTO meta(key, value) VALUES ('layout.expected.word', 'wordkit:1')", []) }
        let result = try other.importChild(child)
        #expect(result.documents == 0 && result.layoutDropped == 1 && result.pages == 0)
        #expect(try other.pendingLayoutJobs().map(\.relativePath) == ["Kunde Ä/2025/a.docx"])
        #expect(try other.match("Wordtext", in: .words).isEmpty)
    }

    @Test func onlyIndexesOfSubfoldersAreFound() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let sibling = env.base.appendingPathComponent("Akten2", isDirectory: true)     // shares the name prefix
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        _ = try env.store(for: sibling)
        _ = try env.store(for: env.child)
        let parentStore = try env.store(for: env.parent)
        #expect(IndexStore.childIndexes(of: env.parent, in: env.indexes, excluding: parentStore.fileURL).map(\.folderPath)
                == [env.child.standardizedFileURL.path])
        #expect(IndexStore.childIndexes(of: env.child, in: env.indexes, excluding: parentStore.fileURL).isEmpty)
    }
}
