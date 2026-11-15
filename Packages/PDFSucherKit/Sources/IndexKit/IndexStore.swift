// IndexStore.swift — Task 1.3
import CryptoKit
import Foundation
import os
import SQLite3
import Synchronization

/// Thrown by `IndexStore` calls when SQLite reported the index file as damaged during use.
/// The store has already discarded the file and recreated an empty index (`wasRebuilt` is
/// true); the caller should tell the user and run the `Indexer` again.
public enum IndexStoreError: Error, Equatable {
    case corruptIndexRebuilt
}

/// The SQLite index of one PDF folder (schema: spec §4.1, extended by spec 1.2 §4).
///
/// - Schema 3 (Office, spec 1.3): `documents.renderer`/`layout_version`/`needs_layout` and
///   `page_text.source = 'layout'` for pages of laid-out Office documents; older indexes are rebuilt.
/// - Schema 2 (OCR): `documents.kind` (`pdf`/`image`); `page_text.source` (`text`/`ocr`: OCR
///   ran on the page) and `page_text.needs_ocr` (the phase-2 queue); `ocr_words` holds the word boxes of recognized pages. An index
///   of schema 1 is rebuilt on open (spec 1.2 §4).
/// - `page_text` holds the normalized text once; `pages_words` (unicode61) and
///   `pages_trigram` (trigram) are external-content FTS5 tables over it, kept in sync by
///   triggers on `page_text`. Deleting a document cascades to its pages, which fires the
///   delete triggers.
/// - Two connections (WAL): one for writes, one for `IndexReading`. Searches therefore do not
///   wait for an indexing transaction to commit; they see the last committed state.
/// - Damage handling: opening deletes and recreates the file only when it is not a database,
///   is corrupt (`SQLITE_NOTADB`, `SQLITE_CORRUPT`) or carries another schema version. Damage
///   found later, during any call, does the same and throws `IndexStoreError.corruptIndexRebuilt`
///   (except `deleteIndex`, which then simply succeeds). Any other error (e.g. `SQLITE_BUSY`)
///   is thrown and the file is left alone. `wasRebuilt` reports whether a rebuild happened.
/// - `modified_at` is seconds since 1970.
public final class IndexStore: IndexReading, @unchecked Sendable {
    public static let schemaVersion = 3

    /// `~/Library/Application Support/PDFSucher/Indexes/<sha256 hex of standardized folder path>.sqlite`
    public static func location(forFolder root: URL) -> URL {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return URL.applicationSupportDirectory
            .appendingPathComponent("PDFSucher", isDirectory: true)
            .appendingPathComponent("Indexes", isDirectory: true)
            .appendingPathComponent("\(hex).sqlite", isDirectory: false)
    }

    private struct Connections {
        var writer: SQLiteConnection
        var reader: SQLiteConnection
        var rebuilt: Bool
        /// Bumped when the connections are replaced after damage.
        var generation = 0
        /// Bumped whenever the index content was wiped (damage rebuild or `deleteIndex`).
        var resets = 0
        /// A rebuild failed (e.g. disk full); the next call retries it.
        var broken = false
    }

    /// Held only to read or swap the connections, never across a statement.
    private let state: Mutex<Connections>
    /// Every call holds this shared for as long as it uses a connection; recovery takes it
    /// exclusively, so no old connection is still open when the files are replaced.
    private let access = ReadWriteLock()
    private let fileURL: URL
    private let root: URL
    private static let log = Logger(subsystem: "local.pdfsucher", category: "IndexStore")

    public var wasRebuilt: Bool { state.withLock { $0.rebuilt } }

    /// Grows each time the index content is wiped (damage rebuild or `deleteIndex`).
    /// The `Indexer` compares it before and after a run to notice a wipe it did not cause.
    var resetCount: Int { state.withLock { $0.resets } }

    public init(fileURL: URL, root: URL) throws {
        self.fileURL = fileURL
        self.root = root
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let (writer, rebuilt) = try Self.open(fileURL: fileURL, root: root)
        let reader = try SQLiteConnection(path: fileURL.path)
        state = Mutex(Connections(writer: writer, reader: reader, rebuilt: rebuilt))
    }

    // MARK: Opening and recovery

    private enum Health { case fresh, current, mismatch }

    private static func open(fileURL: URL, root: URL) throws -> (SQLiteConnection, Bool) {
        do {
            let db = try SQLiteConnection(path: fileURL.path)
            switch try health(of: db) {
            case .current:
                return (db, false)
            case .fresh:
                try createSchema(db, root: root)
                return (db, false)
            case .mismatch:
                log.notice("Index schema mismatch, rebuilding \(fileURL.path, privacy: .public)")
            }
        } catch let error as SQLiteError where isCorruption(error) {
            log.error("Index damaged on open (\(error.description, privacy: .public)), rebuilding \(fileURL.path, privacy: .public)")
        }
        // The first connection is out of scope (closed) here.
        return (try recreate(fileURL: fileURL, root: root), true)
    }

    private static func recreate(fileURL: URL, root: URL) throws -> SQLiteConnection {
        try deleteFiles(of: fileURL)
        let db = try SQLiteConnection(path: fileURL.path)
        try createSchema(db, root: root)
        return db
    }

    static func isCorruption(_ error: Error) -> Bool {
        guard let error = error as? SQLiteError else { return false }
        let primary = error.code & 0xFF
        return primary == SQLITE_NOTADB || primary == SQLITE_CORRUPT
    }

    private enum Role { case writer, reader }

    /// Runs `body` with a connection while holding `access` shared. On corruption the index is
    /// rebuilt and `.corruptIndexRebuilt` is thrown.
    /// Never nest: `body` must not call another store method (a nested shared lock can deadlock
    /// behind a waiting recovery, and recovery from inside would wait for itself).
    private func using<T>(_ role: Role, _ body: (SQLiteConnection) throws -> T) throws -> T {
        let (generation, broken) = state.withLock { ($0.generation, $0.broken) }
        if broken {
            // An earlier rebuild failed; retry it and report the (now empty) index like any
            // other damage rebuild, so callers show the notice and re-index.
            try recover(after: SQLiteError(code: SQLITE_CORRUPT, message: "previous rebuild failed"),
                        seenGeneration: generation)
            throw IndexStoreError.corruptIndexRebuilt
        }
        var seen = 0
        let outcome: Result<T, Error> = access.withReadLock {
            // `db` must not outlive this closure: recovery needs every reference gone.
            let (db, gen) = state.withLock { c in (role == .writer ? c.writer : c.reader, c.generation) }
            seen = gen
            return Result { try body(db) }
        }
        switch outcome {
        case .success(let value):
            return value
        case .failure(let error):
            guard Self.isCorruption(error) else { throw error }
            try recover(after: error, seenGeneration: seen)
            throw IndexStoreError.corruptIndexRebuilt
        }
    }

    /// Replaces both connections with a fresh, empty index file (once per damaged generation).
    private func recover(after error: Error, seenGeneration: Int) throws {
        try access.withWriteLock {
            let (generation, broken) = state.withLock { ($0.generation, $0.broken) }
            guard generation == seenGeneration || broken else { return } // already rebuilt
            Self.log.error("Index damaged (\(String(describing: error), privacy: .public)), rebuilding \(self.fileURL.path, privacy: .public)")
            // Drop the old connections (closing them) before their files are deleted.
            let placeholder = try SQLiteConnection(path: ":memory:")
            state.withLock { c in
                c.writer = placeholder
                c.reader = placeholder
                c.broken = true
            }
            do {
                let writer = try Self.recreate(fileURL: fileURL, root: root)
                let reader = try SQLiteConnection(path: fileURL.path)
                state.withLock { c in
                    c.writer = writer
                    c.reader = reader
                    c.rebuilt = true
                    c.broken = false
                    c.generation += 1
                    c.resets += 1
                }
            } catch {
                Self.log.fault("Rebuilding the index failed: \(String(describing: error), privacy: .public)")
                throw error
            }
        }
    }

    private static func health(of db: SQLiteConnection) throws -> Health {
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type = 'table'", [])
        if tables.isEmpty { return .fresh }
        guard tables.contains(where: { $0["name"] == .text("meta") }) else { return .mismatch }
        let rows = try db.query("SELECT value FROM meta WHERE key = 'schema_version'", [])
        guard rows.count == 1, rows[0]["value"] == .text(String(schemaVersion)) else { return .mismatch }
        return .current
    }

    private static func deleteFiles(of fileURL: URL) throws {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = fileURL.path + suffix
            if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
        }
    }

    private static let schemaSQL = """
        CREATE TABLE documents(
          id INTEGER PRIMARY KEY,
          path TEXT UNIQUE NOT NULL,
          file_size INTEGER NOT NULL,
          modified_at REAL NOT NULL,
          page_count INTEGER NOT NULL,
          status TEXT NOT NULL,
          kind TEXT NOT NULL DEFAULT 'pdf',
          renderer TEXT,
          layout_version INTEGER,
          needs_layout INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX documents_needs_layout ON documents(needs_layout) WHERE needs_layout = 1;
        CREATE TABLE page_text(
          id INTEGER PRIMARY KEY,
          doc_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
          page_index INTEGER NOT NULL,
          text TEXT NOT NULL,
          source TEXT NOT NULL DEFAULT 'text',
          needs_ocr INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX page_text_doc ON page_text(doc_id, page_index);
        CREATE INDEX page_text_needs_ocr ON page_text(needs_ocr) WHERE needs_ocr = 1;
        CREATE TABLE ocr_words(
          page_text_id INTEGER NOT NULL REFERENCES page_text(id) ON DELETE CASCADE,
          start_utf16 INTEGER NOT NULL,
          length_utf16 INTEGER NOT NULL,
          x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL
        );
        CREATE INDEX ocr_words_page ON ocr_words(page_text_id);
        CREATE VIRTUAL TABLE pages_words USING fts5(
          text, content='page_text', content_rowid='id',
          tokenize = 'unicode61 remove_diacritics 2'
        );
        CREATE VIRTUAL TABLE pages_trigram USING fts5(
          text, content='page_text', content_rowid='id',
          tokenize = 'trigram case_sensitive 0 remove_diacritics 1'
        );
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
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
        """

    private static func createSchema(_ db: SQLiteConnection, root: URL) throws {
        try db.transaction {
            try db.execute(schemaSQL)
            try db.run("INSERT INTO meta(key, value) VALUES ('schema_version', ?)", [.text(String(schemaVersion))])
            try db.run("INSERT INTO meta(key, value) VALUES ('folder_path', ?)", [.text(root.standardizedFileURL.path)])
        }
    }

    // MARK: Writing

    /// Runs `body` in one write transaction on the writer connection. Internal (tests).
    /// `body` must use the given connection only, never other store methods (see `using`).
    func batch(_ body: (SQLiteConnection) throws -> Void) throws {
        try using(.writer) { db in try db.transaction { try body(db) } }
    }

    /// Inserts or replaces the document at `file.relativePath` with exactly `pages`.
    /// The document keeps its id when it already exists.
    public func upsert(_ file: ScannedFile, pages: [PageText], status: DocumentStatus) throws {
        try upsertBatch([(file, pages, status)])
    }

    /// Several upserts in one transaction (used by the `Indexer`).
    func upsertBatch(_ items: [(file: ScannedFile, pages: [PageText], status: DocumentStatus)]) throws {
        try upsertBatch(items.map { ($0.file, $0.pages, $0.status, false) })
    }

    /// Several upserts in one transaction; items with `needsLayout` are stored like
    /// `upsertAwaitingLayout` (used by the `Indexer` for Office files).
    func upsertBatch(_ items: [(file: ScannedFile, pages: [PageText], status: DocumentStatus, needsLayout: Bool)]) throws {
        guard !items.isEmpty else { return }
        try using(.writer) { db in
            try db.transaction {
                for item in items {
                    try Self.upsert(item.file, pages: item.pages, status: item.status, needsLayout: item.needsLayout, in: db)
                }
            }
        }
    }

    /// Stores an Office document that still waits for layout: no pages, status `noText` (so search
    /// ignores it), `needs_layout = 1`; an earlier layout (renderer, version, pages) is dropped.
    public func upsertAwaitingLayout(_ file: ScannedFile) throws {
        try using(.writer) { db in
            try db.transaction { try Self.upsert(file, pages: [], status: .noText, needsLayout: true, in: db) }
        }
    }

    private static func upsert(_ file: ScannedFile, pages: [PageText], status: DocumentStatus,
                               needsLayout: Bool = false, in db: SQLiteConnection) throws {
        let existing = try db.query("SELECT id FROM documents WHERE path = ?", [.text(file.relativePath)])
        let docId: Int64
        let meta: [SQLiteValue] = [
            .int(file.fileSize), .double(file.modifiedAt.timeIntervalSince1970),
            .int(Int64(pages.count)), .text(status.rawValue), .text(file.kind.rawValue),
            .int(needsLayout ? 1 : 0),
        ]
        if case .int(let id)? = existing.first?["id"] {
            docId = id
            try db.run("DELETE FROM page_text WHERE doc_id = ?", [.int(id)])
            try db.run("""
                UPDATE documents SET file_size = ?, modified_at = ?, page_count = ?, status = ?, kind = ?,
                  needs_layout = ?, renderer = NULL, layout_version = NULL
                WHERE id = ?
                """, meta + [.int(id)])
        } else {
            docId = try db.run("""
                INSERT INTO documents(path, file_size, modified_at, page_count, status, kind, needs_layout)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, [.text(file.relativePath)] + meta)
        }
        for page in pages {
            try db.run("INSERT INTO page_text(doc_id, page_index, text, needs_ocr) VALUES (?, ?, ?, ?)",
                       [.int(docId), .int(Int64(page.pageIndex)), .text(page.text), .int(page.needsOCR ? 1 : 0)])
        }
    }

    // MARK: OCR (spec 1.2 §3, §4)

    /// Every page still waiting for text recognition, ordered by path and page.
    public func pendingOCRJobs() throws -> [OCRPageJob] {
        try using(.writer) { db in try db.query("""
            SELECT d.id AS id, d.path AS path, d.kind AS kind, d.file_size AS file_size,
                   d.modified_at AS modified_at, p.page_index AS page_index
            FROM page_text p JOIN documents d ON d.id = p.doc_id
            WHERE p.needs_ocr = 1
            ORDER BY d.path, p.page_index
            """, []).map { row in
                OCRPageJob(docId: row.int("id"), relativePath: row.text("path"),
                           kind: DocumentKind(rawValue: row.text("kind")) ?? .pdf,
                           pageIndex: Int(row.int("page_index")), fileSize: row.int("file_size"),
                           modifiedAt: Date(timeIntervalSince1970: row.double("modified_at")))
            } }
    }

    /// Stores the recognition result of one page. A non-empty `text` replaces the page text
    /// (which then counts as `source = 'ocr'` and gets `words`); an empty one keeps the page as it
    /// was: the short text layer of a scan page, or after `resetOCR` the previous result with its
    /// word boxes (text and boxes always stay in step). The page no longer needs OCR; when no page of the document does, the
    /// document is finished: status `ok` if any page has text, else `noText`.
    ///
    /// Returns false and changes nothing when the job is stale: the document is gone, its file
    /// size or date changed since the job was listed (a newer phase 1 re-queued it), or the
    /// page no longer needs OCR.
    @discardableResult
    public func storeOCR(_ job: OCRPageJob, text: String, words: [OCRWord]) throws -> Bool {
        try using(.writer) { db in
            try db.transaction {
                guard let pageId = try Self.currentPage(of: job, in: db) else { return false }
                if text.isEmpty {
                    try db.run("UPDATE page_text SET needs_ocr = 0, source = 'ocr' WHERE id = ?", [.int(pageId)])
                } else {
                    assert(words.allSatisfy { NSMaxRange($0.range) <= (text as NSString).length }, "OCR word outside text")
                    try db.run("DELETE FROM ocr_words WHERE page_text_id = ?", [.int(pageId)])
                    try db.run("UPDATE page_text SET text = ?, needs_ocr = 0, source = 'ocr' WHERE id = ?",
                               [.text(text), .int(pageId)])
                    for word in words {
                        try db.run("""
                            INSERT INTO ocr_words(page_text_id, start_utf16, length_utf16, x, y, w, h)
                            VALUES (?, ?, ?, ?, ?, ?, ?)
                            """, [.int(pageId), .int(Int64(word.range.location)), .int(Int64(word.range.length)),
                                  .double(word.box.minX), .double(word.box.minY),
                                  .double(word.box.width), .double(word.box.height)])
                    }
                }
                try Self.finishIfDone(docId: job.docId, in: db)
                return true
            }
        }
    }

    /// The page of `job` cannot be read for recognition. An image (spec 1.2 §8 „Bild beschädigt“):
    /// the document gets status `error` and nothing of it waits for OCR any more. A PDF page (the
    /// rest of the file was readable in phase 1): only that page is finished, like a page where
    /// OCR found nothing. Stale jobs (see `storeOCR`) return false and change nothing.
    @discardableResult
    public func markOCRUnreadable(_ job: OCRPageJob) throws -> Bool {
        try using(.writer) { db in
            try db.transaction {
                guard let pageId = try Self.currentPage(of: job, in: db) else { return false }
                guard job.kind == .image else {
                    try db.run("UPDATE page_text SET needs_ocr = 0, source = 'ocr' WHERE id = ?", [.int(pageId)])
                    try Self.finishIfDone(docId: job.docId, in: db)
                    return true
                }
                try db.run("UPDATE page_text SET needs_ocr = 0, source = 'ocr' WHERE doc_id = ? AND needs_ocr = 1",
                           [.int(job.docId)])
                try db.run("UPDATE documents SET status = ? WHERE id = ?",
                           [.text(DocumentStatus.error.rawValue), .int(job.docId)])
                return true
            }
        }
    }

    /// „Texterkennung für diese Quelle neu ausführen“ (spec 1.2 §7): every page OCR ran on is
    /// queued again. Its current text stays searchable until the new result replaces it.
    public func resetOCR() throws {
        _ = try using(.writer) { db in
            try db.run("UPDATE page_text SET needs_ocr = 1 WHERE source = 'ocr'", [])
        }
    }

    /// Recognized PDF pages and images (OCR found words) in this index (spec 1.2 §7).
    public func ocrCounts() throws -> (pages: Int, images: Int) {
        try using(.reader) { db in
            let rows = try db.query("""
                SELECT d.kind AS kind, count(*) AS n
                FROM page_text p JOIN documents d ON d.id = p.doc_id
                WHERE p.source = 'ocr' AND EXISTS (SELECT 1 FROM ocr_words w WHERE w.page_text_id = p.id)
                GROUP BY d.kind
                """, [])
            var pages = 0, images = 0
            for row in rows {
                if row.text("kind") == DocumentKind.image.rawValue { images = Int(row.int("n")) } else { pages = Int(row.int("n")) }
            }
            return (pages, images)
        }
    }

    /// The `page_text` id of `job` if the job is still current.
    private static func currentPage(of job: OCRPageJob, in db: SQLiteConnection) throws -> Int64? {
        let rows = try db.query("""
            SELECT p.id AS id, d.file_size AS file_size, d.modified_at AS modified_at
            FROM page_text p JOIN documents d ON d.id = p.doc_id
            WHERE d.id = ? AND d.path = ? AND p.page_index = ? AND p.needs_ocr = 1
            """, [.int(job.docId), .text(job.relativePath), .int(Int64(job.pageIndex))])
        guard let row = rows.first, row.int("file_size") == job.fileSize,
              abs(row.double("modified_at") - job.modifiedAt.timeIntervalSince1970) < 0.001 else { return nil }
        return row.int("id")
    }

    private static func finishIfDone(docId: Int64, in db: SQLiteConnection) throws {
        let open = try db.query("SELECT 1 FROM page_text WHERE doc_id = ? AND needs_ocr = 1 LIMIT 1", [.int(docId)])
        guard open.isEmpty else { return }
        try db.run("""
            UPDATE documents SET
              status = CASE WHEN EXISTS (SELECT 1 FROM page_text WHERE doc_id = ?1 AND text <> '') THEN 'ok' ELSE 'no_text' END
            WHERE id = ?1
            """, [.int(docId)])
    }

    // MARK: Layout (spec 1.3)

    /// Every Office document waiting for layout, ordered by path.
    public func pendingLayoutJobs() throws -> [LayoutJob] {
        try using(.writer) { db in try db.query("""
            SELECT id, path, kind, file_size, modified_at FROM documents WHERE needs_layout = 1 ORDER BY path
            """, []).compactMap { row in
                guard let kind = DocumentKind(rawValue: row.text("kind")), kind.isOffice else {
                    Self.log.error("Skipping layout job with unexpected kind for \(row.text("path"), privacy: .private)")
                    return nil
                }
                return LayoutJob(docId: row.int("id"), relativePath: row.text("path"), kind: kind,
                                 fileSize: row.int("file_size"),
                                 modifiedAt: Date(timeIntervalSince1970: row.double("modified_at")))
            } }
    }

    /// Replaces all pages and word boxes of the document with the laid-out `result` (pages get
    /// `source = 'layout'`), records renderer and version, and finishes the document: status `ok`,
    /// or `noText` when every page is empty. One transaction; the FTS triggers follow the deletes
    /// and inserts.
    ///
    /// Returns false and writes nothing when the job is stale: the document is gone or its file
    /// size or date differ from the job (the file changed during layout).
    @discardableResult
    public func storeLayout(_ job: LayoutJob, result: LayoutResult) throws -> Bool {
        try using(.writer) { db in
            try db.transaction {
                guard try Self.isCurrent(job, in: db) else { return false }
                try db.run("DELETE FROM page_text WHERE doc_id = ?", [.int(job.docId)])
                for (index, page) in result.pages.enumerated() {
                    let length = (page.text as NSString).length
                    let words = page.words.filter { $0.range.location >= 0 && $0.range.length >= 0 && NSMaxRange($0.range) <= length }
                    if words.count != page.words.count {
                        Self.log.error("Dropped \(page.words.count - words.count) layout words outside the text of page \(index) in \(job.relativePath, privacy: .private)")
                    }
                    let pageId = try db.run("""
                        INSERT INTO page_text(doc_id, page_index, text, source) VALUES (?, ?, ?, 'layout')
                        """, [.int(job.docId), .int(Int64(index)), .text(page.text)])
                    for word in words {
                        try db.run("""
                            INSERT INTO ocr_words(page_text_id, start_utf16, length_utf16, x, y, w, h)
                            VALUES (?, ?, ?, ?, ?, ?, ?)
                            """, [.int(pageId), .int(Int64(word.range.location)), .int(Int64(word.range.length)),
                                  .double(word.box.minX), .double(word.box.minY),
                                  .double(word.box.width), .double(word.box.height)])
                    }
                }
                let hasText = result.pages.contains { !$0.text.isEmpty }
                try db.run("""
                    UPDATE documents SET page_count = ?, status = ?, renderer = ?, layout_version = ?, needs_layout = 0
                    WHERE id = ?
                    """, [.int(Int64(result.pages.count)),
                          .text((hasText ? DocumentStatus.ok : .noText).rawValue),
                          .text(result.renderer), .int(Int64(result.layoutVersion)), .int(job.docId)])
                return true
            }
        }
    }

    /// Layout of the document failed: status `error`, no longer waiting; earlier pages, word boxes,
    /// renderer and version are dropped (not readable, so no stale text and no re-queueing by
    /// `requestLayout`). Returns false and changes nothing when the job is stale (see `storeLayout`).
    @discardableResult
    public func markLayoutFailed(_ job: LayoutJob, reason: String) throws -> Bool {
        Self.log.notice("Layout failed for \(job.relativePath, privacy: .private): \(reason, privacy: .private)")
        return try using(.writer) { db in
            try db.transaction {
                guard try Self.isCurrent(job, in: db) else { return false }
                try db.run("DELETE FROM page_text WHERE doc_id = ?", [.int(job.docId)])
                try db.run("""
                    UPDATE documents SET status = ?, needs_layout = 0, page_count = 0, renderer = NULL, layout_version = NULL
                    WHERE id = ?
                    """,
                           [.text(DocumentStatus.error.rawValue), .int(job.docId)])
                return true
            }
        }
    }

    /// Queues every document of `renderer` (and, if given, of `kind`) whose layout version is below
    /// `version` for a new layout. Their current pages stay searchable until the new result replaces
    /// them. `kind` matters when Word and PowerPoint share a renderer name but not its version.
    public func requestLayout(renderer: String, olderThan version: Int, kind: DocumentKind? = nil) throws {
        _ = try using(.writer) { db in
            try db.run("UPDATE documents SET needs_layout = 1 WHERE renderer = ? AND layout_version < ? AND (?3 IS NULL OR kind = ?3)",
                       [.text(renderer), .int(Int64(version)), kind.map { .text($0.rawValue) } ?? .null])
        }
    }

    /// Queues every document of `kind` for a new layout — also failed ones (status `error`) and those
    /// never laid out. Their current pages stay searchable until the new result replaces them. For
    /// a renderer change and for a lost slide cache („Folien-Cache leeren“, cache miss; 1.3 Teil B).
    public func requestLayout(kind: DocumentKind) throws {
        _ = try using(.writer) { db in
            try db.run("UPDATE documents SET needs_layout = 1 WHERE kind = ?", [.text(kind.rawValue)])
        }
    }

    /// Every document of `kind` waits for a new layout like a fresh Office file (no pages, status `noText`, no renderer):
    /// unlike `requestLayout(kind:)` no word of the old layout stays searchable meanwhile. For a renderer switch whose
    /// tiles and highlights would no longer match the old words (1.3 Teil B Task 12, „PowerPoint-Darstellung“).
    public func resetLayout(kind: DocumentKind) throws {
        try using(.writer) { db in try db.transaction { try Self.resetLayout(kind: kind, in: db) } }
    }

    private static func resetLayout(kind: DocumentKind, in db: SQLiteConnection) throws {
        try db.run("DELETE FROM page_text WHERE doc_id IN (SELECT id FROM documents WHERE kind = ?)", [.text(kind.rawValue)])
        try db.run("""
            UPDATE documents SET needs_layout = 1, page_count = 0, status = ?, renderer = NULL, layout_version = NULL
            WHERE kind = ?
            """, [.text(DocumentStatus.noText.rawValue), .text(kind.rawValue)])
    }

    /// Queues exactly this Word/PowerPoint document for a new layout („Neu einlesen“, 1.3 Teil B), also a failed
    /// one. Its current pages stay searchable until the new result replaces them. PDFs, images and unknown paths:
    /// nothing.
    public func requestLayout(relativePath: String) throws {
        _ = try using(.writer) { db in
            try db.run("UPDATE documents SET needs_layout = 1 WHERE path = ? AND kind IN (?, ?)",
                       [.text(relativePath), .text(DocumentKind.word.rawValue), .text(DocumentKind.powerpoint.rawValue)])
        }
    }

    /// Whether any document is stored as laid out by `renderer` (1.3.2: Word with substitute fonts).
    public func hasLayouts(byRenderer renderer: String) throws -> Bool {
        try using(.reader) { db in
            !(try db.query("SELECT 1 FROM documents WHERE renderer = ? LIMIT 1", [.text(renderer)]).isEmpty)
        }
    }

    /// Word and PowerPoint documents by layout state (see `LayoutCounts`).
    public func layoutCounts() throws -> LayoutCounts {
        try using(.reader) { db in
            let rows = try db.query("""
                SELECT kind, needs_layout, status, count(*) AS n FROM documents
                WHERE kind IN (?, ?) GROUP BY kind, needs_layout, status
                """, [.text(DocumentKind.word.rawValue), .text(DocumentKind.powerpoint.rawValue)])
            var counts = LayoutCounts()
            for row in rows {
                let n = Int(row.int("n"))
                let word = row.text("kind") == DocumentKind.word.rawValue
                if row.int("needs_layout") != 0 {
                    counts.waiting += n
                } else if row.text("status") == DocumentStatus.error.rawValue {
                    if word { counts.wordFailed += n } else { counts.powerpointFailed += n }
                } else {
                    if word { counts.wordRead += n } else { counts.powerpointRead += n }
                }
            }
            return counts
        }
    }

    /// The renderer (`name:version`) the documents of `kind` are expected to be laid out with, nil
    /// before the first layout phase (stored in `meta` as `layout.expected.<kind>`).
    public func layoutRenderer(for kind: DocumentKind) throws -> String? {
        try using(.writer) { db in
            try db.query("SELECT value FROM meta WHERE key = ?", [.text(Self.rendererKey(kind))]).first?.optionalText("value")
        }
    }

    /// Records `name`/`version` as the renderer for `kind`. When it differs from the recorded one
    /// (other name or version, or none recorded yet) every document of `kind` is queued for layout
    /// (see `requestLayout(kind:)`), in the same transaction. Returns whether the value changed.
    /// On a fresh index nothing is queued that was not waiting already.
    /// - Parameter clearingPages: on a change from a recorded renderer, also remove the old pages of `kind`
    ///   (`resetLayout(kind:)`) in the same transaction: either both happen or neither (1.3 Teil B, PowerPoint).
    @discardableResult
    public func adoptLayoutRenderer(name: String, version: Int, for kind: DocumentKind, clearingPages: Bool = false) throws -> Bool {
        let key = Self.rendererKey(kind)
        let value = "\(name):\(version)"
        return try using(.writer) { db in
            try db.transaction {
                let current = try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?.optionalText("value")
                guard current != value else { return false }
                try db.run("UPDATE documents SET needs_layout = 1 WHERE kind = ?", [.text(kind.rawValue)])
                if clearingPages, current != nil { try Self.resetLayout(kind: kind, in: db) }
                try db.run("INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           [.text(key), .text(value)])
                return true
            }
        }
    }

    private static func rendererKey(_ kind: DocumentKind) -> String { "layout.expected.\(kind.rawValue)" }

    private static func isCurrent(_ job: LayoutJob, in db: SQLiteConnection) throws -> Bool {
        let rows = try db.query("SELECT file_size, modified_at FROM documents WHERE id = ? AND path = ?",
                                [.int(job.docId), .text(job.relativePath)])
        guard let row = rows.first else { return false }
        return row.int("file_size") == job.fileSize
            && abs(row.double("modified_at") - job.modifiedAt.timeIntervalSince1970) < 0.001
    }

    /// Removes the documents (and their pages); unknown paths are ignored.
    public func remove(relativePaths: [String]) throws {
        guard !relativePaths.isEmpty else { return }
        try using(.writer) { db in
            try db.transaction {
                for path in relativePaths {
                    try db.run("DELETE FROM documents WHERE path = ?", [.text(path)])
                }
            }
        }
    }

    /// Empties the index (all documents, pages and FTS data) and shrinks the file; the old text
    /// is gone from disk (main file and WAL) when this returns. The store stays open and usable.
    /// A damaged file is replaced by a fresh one instead.
    public func deleteIndex() throws {
        do {
            try using(.writer) { db in
                try db.transaction {
                    try db.execute("""
                        DROP TABLE IF EXISTS ocr_words;
                        DROP TABLE IF EXISTS pages_words;
                        DROP TABLE IF EXISTS pages_trigram;
                        DROP TABLE IF EXISTS page_text;
                        DROP TABLE IF EXISTS documents;
                        DROP TABLE IF EXISTS meta;
                        """)
                    try Self.createSchema(db, root: root)
                }
                try db.execute("VACUUM")
                // In WAL mode VACUUM writes to the -wal file; copy it back and truncate both.
                try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            }
            state.withLock { $0.resets += 1 }
        } catch IndexStoreError.corruptIndexRebuilt {
            // The damaged file was replaced by an empty index: that is what was asked for.
        }
    }

    // MARK: IndexReading

    public func documents() throws -> [StoredDocument] {
        try using(.reader) { db in
            try db.query("SELECT \(Self.documentColumns) FROM documents ORDER BY path", []).map(Self.storedDocument)
        }
    }

    /// The stored document at `relativePath` (as stored: precomposed), nil when there is none (1.3 Teil B: is a
    /// file edited during the session still the stored version?).
    public func document(relativePath: String) throws -> StoredDocument? {
        try using(.reader) { db in
            try db.query("SELECT \(Self.documentColumns) FROM documents WHERE path = ?", [.text(relativePath)])
                .first.map(Self.storedDocument)
        }
    }

    private static let documentColumns = "id, path, file_size, modified_at, page_count, status, kind, renderer, layout_version"

    private static func storedDocument(_ row: [String: SQLiteValue]) -> StoredDocument {
        StoredDocument(
            id: row.int("id"),
            relativePath: row.text("path"),
            fileSize: row.int("file_size"),
            modifiedAt: Date(timeIntervalSince1970: row.double("modified_at")),
            pageCount: Int(row.int("page_count")),
            status: DocumentStatus(rawValue: row.text("status")) ?? .error,
            kind: DocumentKind(rawValue: row.text("kind")) ?? .pdf,
            renderer: row.optionalText("renderer"),
            layoutVersion: row.optionalInt("layout_version").map(Int.init))
    }

    /// All pages matching an FTS5 query in the given table (no LIMIT, documents of any status),
    /// ordered by document id and page, with the stored normalized text.
    /// `bm25` is FTS5's raw score: lower (more negative) is more relevant. Invalid FTS5 syntax throws.
    public func match(_ ftsQuery: String, in table: FTSTable) throws -> [RawPageMatch] {
        let name = switch table {
        case .words: "pages_words"
        case .trigram: "pages_trigram"
        }
        return try using(.reader) { db in try db.query("""
            SELECT p.doc_id AS doc_id, p.page_index AS page_index, bm25(\(name)) AS score, p.text AS text
            FROM \(name) JOIN page_text p ON p.id = \(name).rowid
            WHERE \(name) MATCH ?
            ORDER BY p.doc_id, p.page_index
            """, [.text(ftsQuery)]).map(Self.rawMatch) }
    }

    /// Streams the matches in FTS rowid order (no sort, so the first rows come at once); a document's pages
    /// were inserted together, so they are contiguous and ascending.
    public func matchBatches(_ ftsQuery: String, in table: FTSTable, batchSize: Int, _ body: ([RawPageMatch]) throws -> Bool) throws {
        let name = switch table {
        case .words: "pages_words"
        case .trigram: "pages_trigram"
        }
        let size = max(batchSize, 1)
        try using(.reader) { db in
            var batch: [RawPageMatch] = []
            batch.reserveCapacity(size)
            var going = true
            try db.queryEach("""
                SELECT p.doc_id AS doc_id, p.page_index AS page_index, bm25(\(name)) AS score, p.text AS text
                FROM \(name) JOIN page_text p ON p.id = \(name).rowid
                WHERE \(name) MATCH ?
                ORDER BY \(name).rowid
                """, [.text(ftsQuery)]) { row in
                batch.append(Self.rawMatch(row))
                guard batch.count == size else { return true }
                going = try body(batch)
                batch.removeAll(keepingCapacity: true)
                return going
            }
            if going, !batch.isEmpty { _ = try body(batch) }
        }
    }

    /// Every page in batches, in rowid order (a document's pages are contiguous and ascending).
    public func allPagesBatches(batchSize: Int, _ body: ([RawPageMatch]) throws -> Bool) throws {
        let size = max(batchSize, 1)
        try using(.reader) { db in
            var batch: [RawPageMatch] = []
            batch.reserveCapacity(size)
            var going = true
            try db.queryEach("SELECT doc_id, page_index, 0.0 AS score, text FROM page_text ORDER BY id", []) { row in
                batch.append(Self.rawMatch(row))
                guard batch.count == size else { return true }
                going = try body(batch)
                batch.removeAll(keepingCapacity: true)
                return going
            }
            if going, !batch.isEmpty { _ = try body(batch) }
        }
    }

    public func allPages() throws -> [RawPageMatch] {
        try using(.reader) { db in try db.query("""
            SELECT doc_id, page_index, 0.0 AS score, text FROM page_text ORDER BY doc_id, page_index
            """, []).map(Self.rawMatch) }
    }

    /// Stored text and word boxes of a recognized page (spec 1.2 §5) or of a laid-out Word/PowerPoint
    /// page (spec 1.3: highlighted like a recognized image, merge Task 12); nil for pages with a text layer.
    public func ocrPage(relativePath: String, pageIndex: Int) throws -> (text: String, words: [OCRWord])? {
        // One read: text and words of the same version (a recognition storing meanwhile cannot mix them).
        try using(.reader) { db -> (text: String, words: [OCRWord])? in
            guard let row = try db.query("""
                SELECT p.id AS id, p.text AS text FROM page_text p JOIN documents d ON d.id = p.doc_id
                WHERE d.path = ? AND p.page_index = ? AND p.source IN ('ocr', 'layout')
                """, [.text(relativePath), .int(Int64(pageIndex))]).first else { return nil }
            let words = try db.query("""
                SELECT start_utf16 AS s, length_utf16 AS l, x, y, w, h FROM ocr_words WHERE page_text_id = ? ORDER BY rowid
                """, [.int(row.int("id"))]).map { w in
                OCRWord(range: NSRange(location: Int(w.int("s")), length: Int(w.int("l"))),
                        box: CGRect(x: w.double("x"), y: w.double("y"), width: w.double("w"), height: w.double("h")))
            }
            return (row.text("text"), words)
        }
    }

    public func ocrWords(docId: Int64, pageIndex: Int) throws -> [OCRWord] {
        try using(.reader) { db in try db.query("""
            SELECT w.start_utf16 AS s, w.length_utf16 AS l, w.x AS x, w.y AS y, w.w AS w, w.h AS h
            FROM ocr_words w JOIN page_text p ON p.id = w.page_text_id
            WHERE p.doc_id = ? AND p.page_index = ?
            ORDER BY w.rowid
            """, [.int(docId), .int(Int64(pageIndex))]).map { row in
                OCRWord(range: NSRange(location: Int(row.int("s")), length: Int(row.int("l"))),
                        box: CGRect(x: row.double("x"), y: row.double("y"), width: row.double("w"), height: row.double("h")))
            } }
    }

    private static func rawMatch(_ row: [String: SQLiteValue]) -> RawPageMatch {
        RawPageMatch(docId: row.int("doc_id"), pageIndex: Int(row.int("page_index")),
                     bm25: row.double("score"), text: row.text("text"))
    }
}

private extension Dictionary where Key == String, Value == SQLiteValue {
    func int(_ key: String) -> Int64 {
        switch self[key] {
        case .int(let v)?: v
        case .double(let v)?: Int64(v)
        default: 0
        }
    }

    func double(_ key: String) -> Double {
        switch self[key] {
        case .double(let v)?: v
        case .int(let v)?: Double(v)
        default: 0
        }
    }

    func optionalText(_ key: String) -> String? {
        if case .text(let v)? = self[key] { return v }
        return nil
    }

    func optionalInt(_ key: String) -> Int64? {
        if case .int(let v)? = self[key] { return v }
        return nil
    }

    func text(_ key: String) -> String {
        if case .text(let v)? = self[key] { return v }
        return ""
    }
}

/// pthread read/write lock: many readers or one writer.
private final class ReadWriteLock: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<pthread_rwlock_t>

    init() {
        lock = .allocate(capacity: 1)
        pthread_rwlock_init(lock, nil)
    }

    deinit {
        pthread_rwlock_destroy(lock)
        lock.deallocate()
    }

    func withReadLock<T>(_ body: () throws -> T) rethrows -> T {
        let rc = pthread_rwlock_rdlock(lock)
        precondition(rc == 0, "pthread_rwlock_rdlock failed: \(rc)")
        defer { pthread_rwlock_unlock(lock) }
        return try body()
    }

    func withWriteLock<T>(_ body: () throws -> T) rethrows -> T {
        let rc = pthread_rwlock_wrlock(lock)
        precondition(rc == 0, "pthread_rwlock_wrlock failed: \(rc)")
        defer { pthread_rwlock_unlock(lock) }
        return try body()
    }
}

