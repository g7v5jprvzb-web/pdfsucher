import Foundation
@testable import IndexKit
import Synchronization
import Testing
import TestSupport

/// 1.4.0 P4: a file moved or renamed on its volume keeps its entry instead of being read again.
@Suite("Verschobene Dateien wiedererkennen")
struct MovedFilesTests {
    final class Counting: TextSource, Sendable {
        private let calls = Mutex<[String]>([])
        var read: [String] { calls.withLock { $0 } }
        func pages(of url: URL) throws -> [PageText] {
            calls.withLock { $0.append(url.lastPathComponent) }
            return try PDFKitTextSource().pages(of: url)
        }
    }

    struct Env {
        let base: URL, root: URL, store: IndexStore, source = Counting()
        var indexer: Indexer { Indexer(root: root, store: store, source: source) }
        func cleanup() { try? FileManager.default.removeItem(at: base) }
        func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    }

    func makeEnv() throws -> Env {
        let base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        let root = base.appendingPathComponent("pdfs", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Archiv"), withIntermediateDirectories: true)
        try PDFFixtures.makePDF(at: root.appendingPathComponent("vertrag.pdf"), pages: ["Mietvertrag Seite eins", "zwei"])
        try PDFFixtures.makePDF(at: root.appendingPathComponent("brief.pdf"), pages: ["Ein Brief an die Bank"])
        return Env(base: base, root: root, store: try IndexStore(fileURL: base.appendingPathComponent("index.sqlite"), root: root))
    }

    @Test func aRenamedAndAMovedFileAreNotReadAgain() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        _ = try await env.indexer.update { _ in }
        #expect(try env.store.documents().allSatisfy { $0.fileID != nil })
        let before = env.source.read.count
        try FileManager.default.moveItem(at: env.url("vertrag.pdf"), to: env.url("Archiv/Mietvertrag 2025.pdf"))
        try FileManager.default.moveItem(at: env.url("brief.pdf"), to: env.url("bank.pdf"))
        let report = try await env.indexer.update { _ in }
        #expect(env.source.read.count == before, "nothing read again")
        #expect(report.moved == 2 && report.added == 0 && report.removed == 0)
        #expect(try env.store.documents().map(\.relativePath) == ["Archiv/Mietvertrag 2025.pdf", "bank.pdf"])
        #expect(try env.store.match("Mietvertrag", in: .words).count == 1)
        #expect(try env.store.documents().first?.pageCount == 2)
    }

    @Test func aCopyOrAChangedFileIsReadAgain() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        _ = try await env.indexer.update { _ in }
        // A copy has another identity; the original goes: read, not moved.
        try FileManager.default.copyItem(at: env.url("vertrag.pdf"), to: env.url("Archiv/kopie.pdf"))
        try FileManager.default.removeItem(at: env.url("vertrag.pdf"))
        // Renamed and rewritten (another size or date): read.
        try FileManager.default.moveItem(at: env.url("brief.pdf"), to: env.url("bank.pdf"))
        try await Task.sleep(for: .milliseconds(20))
        try PDFFixtures.makePDF(at: env.url("bank.pdf"), pages: ["Ein ganz anderer Brief an die Bank"])
        let report = try await env.indexer.update { _ in }
        #expect(report.moved == 0 && report.added == 2 && report.removed == 2)
        #expect(env.source.read.suffix(2).sorted() == ["bank.pdf", "kopie.pdf"])
    }

    @Test func documentsOfAnOlderIndexGetTheirIdentityAndAreRecognizedLater() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        _ = try await env.indexer.update { _ in }
        try env.store.batch { db in try db.run("UPDATE documents SET file_id = NULL", []) }      // as stored by 1.3.x
        let filled = try await env.indexer.update { _ in }
        #expect(filled.unchanged == 2)
        #expect(try env.store.documents().allSatisfy { $0.fileID != nil })
        let before = env.source.read.count
        try FileManager.default.moveItem(at: env.url("brief.pdf"), to: env.url("Archiv/brief.pdf"))
        #expect(try await env.indexer.update { _ in }.moved == 1)
        #expect(env.source.read.count == before)
    }

    @Test func sharedIdentitiesAndOtherKindsAreNotTrusted() {
        func doc(_ path: String, id: String?) -> StoredDocument {
            var d = StoredDocument(id: 1, relativePath: path, fileSize: 5, modifiedAt: Date(timeIntervalSince1970: 9), pageCount: 1, status: .ok,
                                   kind: DocumentKind(fileExtension: (path as NSString).pathExtension) ?? .pdf)
            d.fileID = id
            return d
        }
        func new(_ path: String, id: String?) -> (file: ScannedFile, isNew: Bool) {
            (ScannedFile(relativePath: path, url: URL(fileURLWithPath: "/x/" + path), fileSize: 5, modifiedAt: Date(timeIntervalSince1970: 9), fileID: id), true)
        }
        #expect(Indexer.moves(new: [new("b.pdf", id: "v/1")], gone: [doc("a.pdf", id: "v/1")]).map(\.to) == ["b.pdf"])
        #expect(Indexer.moves(new: [new("b.pdf", id: "v/1")], gone: [doc("a.pdf", id: "v/1"), doc("c.pdf", id: "v/1")]).isEmpty, "hard links")
        #expect(Indexer.moves(new: [new("b.png", id: "v/1")], gone: [doc("a.pdf", id: "v/1")]).isEmpty, "another kind")
        #expect(Indexer.moves(new: [new("b.pdf", id: nil)], gone: [doc("a.pdf", id: nil)]).isEmpty, "no identity")
    }

    @Test func schema4IndexIsMigratedInPlace() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let url = env.base.appendingPathComponent("index.sqlite")
        try env.store.upsert(ScannedFile(relativePath: "a.pdf", url: env.url("a.pdf"), fileSize: 1, modifiedAt: .distantPast),
                             pages: [PageText(pageIndex: 0, text: "Text")], status: .ok)
        try env.store.batch { db in
            try db.execute("ALTER TABLE documents DROP COLUMN file_id")
            try db.run("UPDATE meta SET value = '4' WHERE key = 'schema_version'", [])
        }
        let reopened = try IndexStore(fileURL: url, root: env.root)
        #expect(!reopened.wasRebuilt)
        #expect(try reopened.documents().map(\.relativePath) == ["a.pdf"])
        #expect(try reopened.documents().first?.fileID == nil)
        let raw = try SQLiteConnection(path: url.path)
        #expect(try raw.query("SELECT value FROM meta WHERE key = 'schema_version'", []).first?["value"] == .text("6"))
    }
}
