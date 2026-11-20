import Testing
import Foundation
@testable import IndexKit
import TestSupport
import Synchronization

@Suite("IndexStore")
struct IndexStoreTests {
    private let root = URL(fileURLWithPath: "/tmp/PDFSucherRoot", isDirectory: true)

    private func file(_ path: String, size: Int64 = 100, modified: TimeInterval = 1_700_000_000) -> ScannedFile {
        ScannedFile(relativePath: path, url: root.appendingPathComponent(path), fileSize: size,
                    modifiedAt: Date(timeIntervalSince1970: modified))
    }

    private func withStore(_ body: (URL, IndexStore) throws -> Void) throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")
        try body(url, try IndexStore(fileURL: url, root: root))
    }

    @Test func locationIsHashOfStandardizedPath() {
        let a = IndexStore.location(forFolder: URL(fileURLWithPath: "/Users/x/PDFs"))
        let b = IndexStore.location(forFolder: URL(fileURLWithPath: "/Users/x/./PDFs/"))
        #expect(a == b)
        #expect(a.pathExtension == "sqlite")
        #expect(a.deletingPathExtension().lastPathComponent.count == 64)
        #expect(a.deletingLastPathComponent().path.hasSuffix("Application Support/PDFSearch/Indexes"))
        #expect(a != IndexStore.location(forFolder: URL(fileURLWithPath: "/Users/x/Other")))
    }

    @Test func freshStoreIsEmptyAndNotRebuilt() throws {
        try withStore { _, store throws in
            #expect(store.wasRebuilt == false)
            #expect(try store.documents().isEmpty)
            #expect(try store.allPages().isEmpty)
        }
    }

    @Test func createsMissingParentDirectory() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a/b/index.sqlite")
        _ = try IndexStore(fileURL: url, root: root)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func upsertThenMatchWords() throws {
        try withStore { _, store throws in
            try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "Der Vertrag endet")], status: .ok)
            let hits = try store.match("vertrag", in: .words)
            #expect(hits.count == 1)
            #expect(hits.first?.pageIndex == 0)
            #expect(hits.first?.text == "Der Vertrag endet")
            let docId = try store.documents().first?.id
            #expect(hits.first?.docId == docId)
            #expect((hits.first?.bm25 ?? 0) < 0) // FTS5 bm25: lower (more negative) = better
        }
    }

    /// 1.1 §5: matches stream in batches (rowid order), so the first documents can be shown early.
    @Test func matchBatchesStreamAllPagesAndCanStop() throws {
        try withStore { _, store throws in
            for d in 0..<5 {
                try store.upsert(file("d\(d).pdf"), pages: (0..<3).map { PageText(pageIndex: $0, text: "Vertrag \(d) \($0)") }, status: .ok)
            }
            var batches: [[RawPageMatch]] = []
            try store.matchBatches("vertrag", in: .words, batchSize: 4) { batches.append($0); return true }
            #expect(batches.map(\.count) == [4, 4, 4, 3])
            let streamed = batches.flatMap { $0 }
            let all = try store.match("vertrag", in: .words)
            #expect(Set(streamed.map { "\($0.docId)/\($0.pageIndex)" }) == Set(all.map { "\($0.docId)/\($0.pageIndex)" }))
            // A document's pages are contiguous and ascending in the stream.
            let order = streamed.map(\.docId)
            #expect(order == order.sorted())
            var count = 0
            try store.matchBatches("vertrag", in: .words, batchSize: 4) { count += $0.count; return false }
            #expect(count == 4)
        }
    }

    /// Review of the early results: after re-indexing an earlier document its pages are still contiguous,
    /// in match and full-scan streams.
    @Test func streamsKeepDocumentsContiguousAfterUpdate() throws {
        try withStore { _, store throws in
            for d in 0..<3 {
                try store.upsert(file("d\(d).pdf"), pages: (0..<3).map { PageText(pageIndex: $0, text: "Vertrag \($0)") }, status: .ok)
            }
            try store.upsert(file("d0.pdf", modified: 1_800_000_000), pages: (0..<4).map { PageText(pageIndex: $0, text: "Vertrag neu \($0)") }, status: .ok)
            for stream in ["match", "all"] {
                var rows: [RawPageMatch] = []
                if stream == "match" {
                    try store.matchBatches("vertrag", in: .words, batchSize: 2) { rows += $0; return true }
                } else {
                    try store.allPagesBatches(batchSize: 2) { rows += $0; return true }
                }
                #expect(rows.count == 10, "\(stream)")
                var seen: [Int64] = []
                for row in rows where seen.last != row.docId {
                    #expect(!seen.contains(row.docId), "\(stream): document \(row.docId) split")
                    seen.append(row.docId)
                }
                for doc in Set(rows.map(\.docId)) {
                    let pages = rows.filter { $0.docId == doc }.map(\.pageIndex)
                    #expect(pages == pages.sorted(), "\(stream)")
                }
            }
        }
    }

    @Test func wordsIgnoreCaseAndDiacritics() throws {
        try withStore { _, store throws in
            try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "Herr Müller")], status: .ok)
            #expect(try store.match("muller", in: .words).count == 1)
            #expect(try store.match("MÜLLER", in: .words).count == 1)
        }
    }

    @Test func trigramFindsInfix() throws {
        try withStore { _, store throws in
            try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "Vertragsende")], status: .ok)
            try store.fillTrigramIndex(maxPages: 1_000)          // schema 4: phase-1 pages wait for the trigram index
            #expect(try store.match("\"trag\"", in: .trigram).count == 1)
            #expect(try store.match("\"trag\"", in: .words).isEmpty)
            #expect(try store.match("\"ANDERUNG\"", in: .trigram).isEmpty)
        }
    }

    @Test func storesDocumentMetadata() throws {
        try withStore { _, store throws in
            let f = file("sub/b.pdf", size: 1234, modified: 1_700_000_123.456789)
            try store.upsert(f, pages: [PageText(pageIndex: 0, text: "x"), PageText(pageIndex: 1, text: "y")], status: .ok)
            try store.upsert(file("bad.pdf"), pages: [], status: .error)
            try store.upsert(file("empty.pdf"), pages: [PageText(pageIndex: 0, text: "")], status: .noText)
            let docs = try store.documents()
            #expect(docs.map(\.relativePath) == ["bad.pdf", "empty.pdf", "sub/b.pdf"])
            let b = try #require(docs.last)
            #expect(b.fileSize == 1234)
            #expect(abs(b.modifiedAt.timeIntervalSince1970 - 1_700_000_123.456789) < 1e-6)
            #expect(b.pageCount == 2)
            #expect(b.status == .ok)
            #expect(docs[0].status == .error && docs[0].pageCount == 0)
            #expect(docs[1].status == .noText && docs[1].pageCount == 1)
        }
    }

    @Test func allPagesListsEveryPageWithZeroScore() throws {
        try withStore { _, store throws in
            try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "eins"), PageText(pageIndex: 1, text: "zwei")], status: .ok)
            try store.upsert(file("b.pdf"), pages: [PageText(pageIndex: 0, text: "drei")], status: .ok)
            let pages = try store.allPages()
            #expect(pages.map(\.text) == ["eins", "zwei", "drei"])
            #expect(pages.allSatisfy { $0.bm25 == 0 })
        }
    }

    @Test func upsertReplacesPages() throws {
        try withStore { _, store throws in
            try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "alter Inhalt")], status: .ok)
            let firstId = try store.documents().first?.id
            try store.upsert(file("a.pdf", size: 200), pages: [PageText(pageIndex: 0, text: "neuer Text")], status: .ok)
            try store.fillTrigramIndex(maxPages: 1_000)
            #expect(try store.match("alter", in: .words).isEmpty)
            #expect(try store.match("\"alt\"", in: .trigram).isEmpty)
            #expect(try store.match("neuer", in: .words).count == 1)
            let docs = try store.documents()
            #expect(docs.count == 1)
            #expect(docs.first?.id == firstId)
            #expect(docs.first?.fileSize == 200)
            #expect(try store.allPages().count == 1)
        }
    }

    /// FTS5 integrity check against the content table: catches stale or missing FTS rows,
    /// which a JOIN with page_text would hide. Schema 4: the trigram index holds every page only once the waiting ones
    /// are moved in, so they are moved first (a page indexed twice or a wrong delete would still show).
    private func expectFTSIntact(_ url: URL, _ store: IndexStore) throws {
        while try store.fillTrigramIndex(maxPages: 1_000) > 0 {}
        let raw = try SQLiteConnection(path: url.path)
        for table in ["pages_words", "pages_trigram"] {
            #expect(throws: Never.self) {
                try raw.run("INSERT INTO \(table)(\(table), rank) VALUES ('integrity-check', 1)", [])
            }
        }
    }

    @Test func ftsStaysInSyncThroughUpsertReplaceAndRemove() throws {
        try withStore { url, store throws in
            try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "eins zwei"), PageText(pageIndex: 1, text: "drei")], status: .ok)
            try store.upsert(file("b.pdf"), pages: [PageText(pageIndex: 0, text: "vier")], status: .ok)
            try expectFTSIntact(url, store)
            try store.upsert(file("a.pdf", size: 1), pages: [PageText(pageIndex: 0, text: "fünf")], status: .ok)
            try expectFTSIntact(url, store)
            try store.remove(relativePaths: ["b.pdf"])
            try expectFTSIntact(url, store)
            try store.deleteIndex()
            try expectFTSIntact(url, store)
        }
    }

    @Test func readsDoNotWaitForAWriteTransaction() throws {
        try withStore { _, store throws in
            try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "Vertrag")], status: .ok)
            let started = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let writerStillOpen = Mutex(false)
            Thread.detachNewThread {
                defer { finished.signal() }
                do {
                    try store.batch { db in
                        // Takes SQLite's write lock and keeps the transaction open.
                        try db.run("INSERT INTO meta(key, value) VALUES ('probe', 'x')", [])
                        writerStillOpen.withLock { $0 = true }
                        started.signal()
                        Thread.sleep(forTimeInterval: 0.5)
                        writerStillOpen.withLock { $0 = false }
                    }
                } catch {
                    started.signal()
                    Issue.record("batch failed: \(error)")
                }
            }
            started.wait()
            let hits = try store.match("vertrag", in: .words).count
            let readFinishedWhileWriting = writerStillOpen.withLock { $0 }
            #expect(hits == 1)
            #expect(readFinishedWhileWriting)
            finished.wait()
        }
    }

    @Test func deleteIndexRemovesTextFromDiskWhileOpen() throws {
        try withStore { url, store throws in
            let marker = "Quellwasserzeichen"
            for i in 0..<200 {
                let pages = (0..<5).map { PageText(pageIndex: $0, text: "\(marker) Seite \($0) Dokument \(i) " + String(repeating: "Füllwort ", count: 40)) }
                try store.upsert(file("f\(i).pdf"), pages: pages, status: .ok)
            }
            let before = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            try store.deleteIndex()
            let mainData = try Data(contentsOf: url)
            #expect(mainData.count < before / 4)
            #expect(mainData.range(of: Data(marker.utf8)) == nil)
            let walURL = URL(fileURLWithPath: url.path + "-wal")
            if let wal = try? Data(contentsOf: walURL) {
                #expect(wal.range(of: Data(marker.utf8)) == nil)
            }
            #expect(try store.documents().isEmpty)
        }
    }

    @Test func resetCountGrowsOnDeleteAndRecovery() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")
        try makeIndexWithCorruptDocumentsPage(at: url)
        let store = try IndexStore(fileURL: url, root: root)
        let start = store.resetCount
        try store.deleteIndex()
        #expect(store.resetCount == start + 1)
        try store.upsert(file("a.pdf"), pages: [], status: .error)
        try store.deleteIndex()
        #expect(store.resetCount == start + 2)
    }

    @Test func removeDeletesPages() throws {
        try withStore { _, store throws in
            try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "Vertrag")], status: .ok)
            try store.upsert(file("b.pdf"), pages: [PageText(pageIndex: 0, text: "Vertrag")], status: .ok)
            try store.remove(relativePaths: ["a.pdf", "not-there.pdf"])
            #expect(try store.documents().map(\.relativePath) == ["b.pdf"])
            #expect(try store.match("vertrag", in: .words).count == 1)
            #expect(try store.match("\"rtra\"", in: .trigram).count == 1)
            #expect(try store.allPages().count == 1)
        }
    }

    @Test func reopensExistingIndex() throws {
        try withStore { url, store throws in
            try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "Vertrag")], status: .ok)
            let reopened = try IndexStore(fileURL: url, root: root)
            #expect(reopened.wasRebuilt == false)
            #expect(try reopened.documents().map(\.relativePath) == ["a.pdf"])
            #expect(try reopened.match("vertrag", in: .words).count == 1)
        }
    }

    @Test func rebuildsOnSchemaMismatch() throws {
        try withStore { url, store throws in
            try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "Vertrag")], status: .ok)
            let raw = try SQLiteConnection(path: url.path)
            try raw.run("UPDATE meta SET value = '0' WHERE key = 'schema_version'", [])
            let reopened = try IndexStore(fileURL: url, root: root)
            #expect(reopened.wasRebuilt == true)
            #expect(try reopened.documents().isEmpty)
            #expect(try reopened.match("vertrag", in: .words).isEmpty)
            // The rebuilt index is current: opening again does not rebuild.
            #expect(try IndexStore(fileURL: url, root: root).wasRebuilt == false)
        }
    }

    @Test func rebuildsWhenMetaIsMissing() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")
        let raw = try SQLiteConnection(path: url.path)
        try raw.execute("CREATE TABLE something_else(x)")
        let store = try IndexStore(fileURL: url, root: root)
        #expect(store.wasRebuilt == true)
        #expect(try store.documents().isEmpty)
    }

    @Test func rebuildsOnCorruptFile() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<8192).map { _ in UInt8.random(in: 0...255, using: &generator) }
        try Data(bytes).write(to: url)
        let store = try IndexStore(fileURL: url, root: root)
        #expect(store.wasRebuilt == true)
        try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "Vertrag")], status: .ok)
        #expect(try store.match("vertrag", in: .words).count == 1)
    }

    @Test func rebuildRemovesStaleWalAndShm() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")
        try Data(repeating: 0xAB, count: 8192).write(to: url)
        try Data(repeating: 0xCD, count: 4096).write(to: URL(fileURLWithPath: url.path + "-wal"))
        try Data(repeating: 0xEF, count: 4096).write(to: URL(fileURLWithPath: url.path + "-shm"))
        let store = try IndexStore(fileURL: url, root: root)
        #expect(store.wasRebuilt)
        try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "Vertrag")], status: .ok)
        #expect(try store.match("vertrag", in: .words).count == 1)
    }

    /// Writes an index, closes it, then overwrites the root page of `documents` with garbage.
    /// The header and schema stay intact, so opening succeeds and the damage shows on first use.
    private func makeIndexWithCorruptDocumentsPage(at url: URL) throws {
        do {
            let store = try IndexStore(fileURL: url, root: root)
            for i in 0..<50 {
                try store.upsert(file("f\(i).pdf"), pages: [PageText(pageIndex: 0, text: "Seite \(i) Vertrag")], status: .ok)
            }
        }
        let (rootPage, pageSize): (Int64, Int64) = try {
            let raw = try SQLiteConnection(path: url.path)
            try raw.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            let r = try raw.query("SELECT rootpage FROM sqlite_master WHERE name = 'documents'", [])
            let p = try raw.query("PRAGMA page_size", [])
            guard case .int(let rp)? = r.first?["rootpage"], case .int(let ps)? = p.first?["page_size"] else {
                throw SQLiteError(code: 1, message: "no rootpage")
            }
            return (rp, ps)
        }()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: UInt64((rootPage - 1) * pageSize))
        try handle.write(contentsOf: Data(repeating: 0x5A, count: Int(pageSize)))
        try handle.close()
    }

    @Test func corruptionFoundDuringUseRebuildsTheIndex() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")
        try makeIndexWithCorruptDocumentsPage(at: url)
        let store = try IndexStore(fileURL: url, root: root)
        #expect(store.wasRebuilt == false) // header and schema look fine at open
        #expect(throws: IndexStoreError.corruptIndexRebuilt) { try store.documents() }
        #expect(store.wasRebuilt)
        #expect(try store.documents().isEmpty)
        try store.upsert(file("neu.pdf"), pages: [PageText(pageIndex: 0, text: "Angebot")], status: .ok)
        #expect(try store.match("angebot", in: .words).count == 1)
        #expect(try IndexStore(fileURL: url, root: root).wasRebuilt == false)
    }

    @Test func deleteIndexRecoversFromCorruption() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")
        try makeIndexWithCorruptDocumentsPage(at: url)
        let store = try IndexStore(fileURL: url, root: root)
        try store.deleteIndex()
        #expect(try store.documents().isEmpty)
        try store.upsert(file("neu.pdf"), pages: [PageText(pageIndex: 0, text: "Angebot")], status: .ok)
        #expect(try store.match("angebot", in: .words).count == 1)
    }

    @Test func deleteIndexEmptiesStoreAndKeepsItUsable() throws {
        try withStore { url, store throws in
            try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "Vertrag")], status: .ok)
            try store.deleteIndex()
            #expect(try store.documents().isEmpty)
            #expect(try store.match("vertrag", in: .words).isEmpty)
            #expect(try store.allPages().isEmpty)
            try store.upsert(file("b.pdf"), pages: [PageText(pageIndex: 0, text: "Angebot")], status: .ok)
            #expect(try store.match("angebot", in: .words).count == 1)
            #expect(try IndexStore(fileURL: url, root: root).wasRebuilt == false)
        }
    }

    @Test func textWithQuotesAndNulIsStoredVerbatim() throws {
        try withStore { _, store throws in
            let text = "Er sagte \"Hallo\" ' ; DROP TABLE documents; -- \u{0}ende"
            try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: text)], status: .ok)
            #expect(try store.allPages().first?.text == text)
            #expect(try store.documents().count == 1)
        }
    }
}
