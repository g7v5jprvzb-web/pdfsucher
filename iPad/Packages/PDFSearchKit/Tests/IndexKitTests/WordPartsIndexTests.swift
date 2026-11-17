import Foundation
@testable import IndexKit
import Testing
import TestSupport

/// 1.3.12: the trigram index („Wortteil-Index“) of phase-1 pages is filled later; until then the pages wait in
/// `trigram_pending` and trigram searches take them as candidates.
@Suite("Wortteil-Index im Hintergrund")
struct WordPartsIndexTests {
    let root = URL(fileURLWithPath: "/tmp/pdfs", isDirectory: true)

    func file(_ path: String, size: Int64 = 100) -> ScannedFile {
        ScannedFile(relativePath: path, url: root.appendingPathComponent(path), fileSize: size, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func withStore(_ body: (URL, IndexStore) throws -> Void) throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")
        try body(url, try IndexStore(fileURL: url, root: root))
    }

    /// Both FTS indexes against the content table (`rank = 1`: compares with `page_text`); the trigram index only once
    /// every waiting page is in it.
    func expectIntact(_ url: URL, _ store: IndexStore) throws {
        let raw = try SQLiteConnection(path: url.path)
        try raw.run("INSERT INTO pages_words(pages_words, rank) VALUES ('integrity-check', 1)", [])
        #expect(try store.trigramProgress().pending == 0)
        try raw.run("INSERT INTO pages_trigram(pages_trigram, rank) VALUES ('integrity-check', 1)", [])
    }

    func fillAll(_ store: IndexStore) throws { while try store.fillTrigramIndex(maxPages: 1_000) > 0 {} }

    func docs(_ store: IndexStore, _ query: String) throws -> Set<String> {
        let byId = Dictionary(uniqueKeysWithValues: try store.documents().map { ($0.id, $0.relativePath) })
        return Set(try store.match(query, in: .trigram).compactMap { byId[$0.docId] })
    }

    @Test func phaseOnePagesWaitForTheTrigramIndexButNotForTheWordIndex() throws {
        try withStore { _, store in
            try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "Vertragsende"), PageText(pageIndex: 1, text: "zwei")], status: .ok)
            #expect(try store.trigramProgress() == (pending: 2, pages: 2))
            #expect(try store.match("Vertragsende", in: .words).count == 1)
            #expect(try store.fillTrigramIndex(maxPages: 1_000) == 2)
            #expect(try store.trigramProgress().pending == 0)
            #expect(try store.fillTrigramIndex(maxPages: 1_000) == 0)
            #expect(try store.match("\"trag\"", in: .trigram).count == 1)
        }
    }

    @Test func trigramSearchTakesWaitingPagesAsCandidates() throws {
        try withStore { _, store in
            try store.upsert(file("indexed.pdf"), pages: [PageText(pageIndex: 0, text: "Vertragsende")], status: .ok)
            try fillAll(store)
            try store.upsert(file("waiting.pdf"), pages: [PageText(pageIndex: 0, text: "Mietvertrag"), PageText(pageIndex: 1, text: "Anlage")], status: .ok)
            try store.upsert(file("other.pdf"), pages: [PageText(pageIndex: 0, text: "Kaufpreis")], status: .ok)
            // Waiting pages are candidates (the matcher decides), indexed ones only when they match.
            #expect(try docs(store, "\"trag\"") == ["indexed.pdf", "waiting.pdf", "other.pdf"])
            #expect(try docs(store, "\"kauf\"") == ["waiting.pdf", "other.pdf"])
            // Streamed in batches: every page once, each document's pages together.
            var seen: [Int64] = [], pages = 0
            try store.matchBatches("\"trag\"", in: .trigram, batchSize: 1) { batch in
                pages += batch.count
                for page in batch where seen.last != page.docId { seen.append(page.docId) }
                return true
            }
            #expect(pages == 4)
            #expect(seen.count == Set(seen).count, "a document's pages are contiguous")
            try fillAll(store)
            #expect(try docs(store, "\"trag\"") == ["indexed.pdf", "waiting.pdf"])
            // The word index never waits.
            #expect(try store.match("\"trag\"", in: .words).isEmpty)
        }
    }

    @Test func changesKeepBothIndexesConsistentWhetherAPageWaitsOrNot() throws {
        try withStore { url, store in
            try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "alter Inhalt")], status: .ok)
            // Images: one recognized after its page reached the trigram index (x), one while it still waits (y).
            try store.upsert(file("x.png"), pages: [PageText(pageIndex: 0, text: "", needsOCR: true)], status: .noText)
            try fillAll(store)                                                 // a, x: indexed
            try store.upsert(file("b.pdf"), pages: [PageText(pageIndex: 0, text: "wartet noch")], status: .ok)   // b: waiting
            try store.upsert(file("a.pdf", size: 200), pages: [PageText(pageIndex: 0, text: "neuer Text")], status: .ok)   // indexed page replaced
            try store.upsert(file("b.pdf", size: 200), pages: [PageText(pageIndex: 0, text: "anderes")], status: .ok)      // waiting page replaced
            try store.upsert(file("c.pdf"), pages: [PageText(pageIndex: 0, text: "weg")], status: .ok)
            try store.remove(relativePaths: ["c.pdf"])                                                                    // waiting page removed
            try store.upsert(file("y.png"), pages: [PageText(pageIndex: 0, text: "", needsOCR: true)], status: .noText)
            for job in try store.pendingOCRJobs() {
                #expect(try store.storeOCR(job, text: job.relativePath == "x.png" ? "Ortsteil" : "Wortteil", words: []))
            }
            // A laid-out page goes into both indexes at once.
            try store.batch { db in
                let id = try db.run("INSERT INTO documents(path, file_size, modified_at, page_count, status, kind) VALUES ('d.docx', 1, 0, 1, 'ok', 'word')", [])
                try db.run("INSERT INTO page_text(doc_id, page_index, text, source) VALUES (?, 0, 'Layoutseite', 'layout')", [.int(id)])
            }
            #expect(try store.trigramProgress().pending == 3)
            // Waiting now: a.pdf and b.pdf (replaced after the fill / never filled) and y.png.
            #expect(try docs(store, "\"outs\"") == ["d.docx", "a.pdf", "b.pdf", "y.png"], "laid out: found; waiting: candidates")
            #expect(try docs(store, "\"tste\"") == ["x.png", "a.pdf", "b.pdf", "y.png"], "recognized after indexing: in the index at once")
            #expect(try docs(store, "\"alt\"") == ["a.pdf", "b.pdf", "y.png"])
            try fillAll(store)
            #expect(try docs(store, "\"alt\"").isEmpty)
            #expect(try docs(store, "\"rtte\"") == ["y.png"])
            try expectIntact(url, store)
        }
    }

    @Test func fillMovesWholeDocuments() throws {
        try withStore { _, store in
            try store.upsert(file("a.pdf"), pages: (0..<3).map { PageText(pageIndex: $0, text: "Seite \($0)") }, status: .ok)
            try store.upsert(file("b.pdf"), pages: [PageText(pageIndex: 0, text: "b")], status: .ok)
            #expect(try store.fillTrigramIndex(maxPages: 2) == 3)
            #expect(try store.trigramProgress().pending == 1)
        }
    }

    /// An index of 1.3.11 (schema 3, every page in the trigram index) is migrated in place: nothing is rebuilt or
    /// re-indexed, its trigram search keeps working, new pages wait.
    @Test func schema3IndexIsMigratedInPlace() throws {
        try withStore { url, store in
            try store.upsert(file("a.pdf"), pages: [PageText(pageIndex: 0, text: "Vertragsende")], status: .ok)
            try fillAll(store)
            try store.batch { db in
                try db.execute("""
                    DROP TRIGGER page_text_ai; DROP TRIGGER page_text_ad; DROP TRIGGER page_text_au;
                    DROP TABLE trigram_pending;
                    ALTER TABLE documents DROP COLUMN file_id;
                    CREATE TRIGGER page_text_ai AFTER INSERT ON page_text BEGIN
                      INSERT INTO pages_words(rowid, text) VALUES (new.id, new.text);
                      INSERT INTO pages_trigram(rowid, text) VALUES (new.id, new.text);
                    END;
                    CREATE TRIGGER page_text_ad AFTER DELETE ON page_text BEGIN
                      INSERT INTO pages_words(pages_words, rowid, text) VALUES ('delete', old.id, old.text);
                      INSERT INTO pages_trigram(pages_trigram, rowid, text) VALUES ('delete', old.id, old.text);
                    END;
                    CREATE TRIGGER page_text_au AFTER UPDATE OF text ON page_text BEGIN
                      INSERT INTO pages_words(pages_words, rowid, text) VALUES ('delete', old.id, old.text);
                      INSERT INTO pages_trigram(pages_trigram, rowid, text) VALUES ('delete', old.id, old.text);
                      INSERT INTO pages_words(rowid, text) VALUES (new.id, new.text);
                      INSERT INTO pages_trigram(rowid, text) VALUES (new.id, new.text);
                    END;
                    UPDATE meta SET value = '3' WHERE key = 'schema_version';
                    """)
            }
            let reopened = try IndexStore(fileURL: url, root: root)
            #expect(!reopened.wasRebuilt)
            #expect(try reopened.documents().map(\.relativePath) == ["a.pdf"])
            #expect(try reopened.trigramProgress() == (pending: 0, pages: 1))
            #expect(try docs(reopened, "\"trag\"") == ["a.pdf"])
            try reopened.upsert(file("b.pdf"), pages: [PageText(pageIndex: 0, text: "neu")], status: .ok)
            #expect(try reopened.trigramProgress().pending == 1)
            try reopened.remove(relativePaths: ["a.pdf"])                     // an old page leaves the index cleanly
            try fillAll(reopened)
            try expectIntact(url, reopened)
            let raw = try SQLiteConnection(path: url.path)
            #expect(try raw.query("SELECT value FROM meta WHERE key = 'schema_version'", []).first?["value"] == .text("5"))    // 1.4.0: on to schema 5
        }
    }

    /// Cancelled after its first transaction, `buildWordParts` keeps what it moved; the next call finishes the rest.
    @Test func buildingStopsOnCancelAndContinuesLater() async throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try IndexStore(fileURL: dir.appendingPathComponent("index.sqlite"), root: root)
        for d in 0..<30 {
            try store.upsert(file("d\(d).pdf"), pages: (0..<50).map { PageText(pageIndex: $0, text: "Seite \(d)-\($0)") }, status: .ok)
        }
        let indexer = Indexer(root: root, store: store)
        await #expect(throws: CancellationError.self) {
            _ = try await indexer.buildWordParts { progress in
                if progress.done > 0 { withUnsafeCurrentTask { $0?.cancel() } }       // cancel after the first transaction
            }
        }
        let left = try store.trigramProgress().pending
        #expect(left == 1_500 - Indexer.wordPartsBatch)
        #expect(try await indexer.buildWordParts { _ in } == left)
        #expect(try store.trigramProgress().pending == 0)
        try expectIntact(dir.appendingPathComponent("index.sqlite"), store)
    }
}
