import Foundation
import IndexKit

/// Test-only `IndexReading` backed by real SQLite FTS5 with the spec's schema (§4.1).
/// Phase 1 owns the production `IndexStore`; this stand-in lets SearchKit exercise real
/// FTS5 queries (word table, prefix, phrase, trigram) on its own branch.
final class TestIndex: IndexReading, @unchecked Sendable {
    private let db: SQLiteConnection

    init() throws {
        db = try SQLiteConnection(path: ":memory:")
        try db.execute("""
            CREATE TABLE documents(
              id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, file_size INTEGER NOT NULL,
              modified_at REAL NOT NULL, page_count INTEGER NOT NULL, status TEXT NOT NULL);
            CREATE TABLE page_text(
              id INTEGER PRIMARY KEY,
              doc_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
              page_index INTEGER NOT NULL, text TEXT NOT NULL);
            CREATE VIRTUAL TABLE pages_words USING fts5(
              text, content='page_text', content_rowid='id',
              tokenize = 'unicode61 remove_diacritics 2');
            CREATE VIRTUAL TABLE pages_trigram USING fts5(
              text, content='page_text', content_rowid='id',
              tokenize = 'trigram case_sensitive 0 remove_diacritics 1');
            """)
    }

    @discardableResult
    func add(_ path: String, pages: [String], status: DocumentStatus = .ok,
             modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws -> Int64 {
        let docId = try db.run(
            "INSERT INTO documents(path, file_size, modified_at, page_count, status) VALUES(?,?,?,?,?)",
            [.text(path), .int(1), .double(modifiedAt.timeIntervalSince1970), .int(Int64(pages.count)), .text(status.rawValue)])
        for (i, text) in pages.enumerated() {
            let rowid = try db.run("INSERT INTO page_text(doc_id, page_index, text) VALUES(?,?,?)",
                                   [.int(docId), .int(Int64(i)), .text(text)])
            _ = try db.run("INSERT INTO pages_words(rowid, text) VALUES(?,?)", [.int(rowid), .text(text)])
            _ = try db.run("INSERT INTO pages_trigram(rowid, text) VALUES(?,?)", [.int(rowid), .text(text)])
        }
        return docId
    }

    func documents() throws -> [StoredDocument] {
        try db.query("SELECT id, path, file_size, modified_at, page_count, status FROM documents", []).map { row in
            StoredDocument(id: row["id"]!.int, relativePath: row["path"]!.text, fileSize: row["file_size"]!.int,
                           modifiedAt: Date(timeIntervalSince1970: row["modified_at"]!.double),
                           pageCount: Int(row["page_count"]!.int),
                           status: DocumentStatus(rawValue: row["status"]!.text)!)
        }
    }

    func match(_ ftsQuery: String, in table: FTSTable) throws -> [RawPageMatch] {
        let t = table == .words ? "pages_words" : "pages_trigram"
        return try db.query("""
            SELECT p.doc_id AS doc_id, p.page_index AS page_index, bm25(\(t)) AS score, p.text AS text
            FROM \(t) JOIN page_text p ON p.id = \(t).rowid WHERE \(t) MATCH ?
            """, [.text(ftsQuery)]).map(Self.page)
    }

    func allPages() throws -> [RawPageMatch] {
        try db.query("SELECT doc_id, page_index, 0.0 AS score, text FROM page_text", []).map(Self.page)
    }

    private static func page(_ row: [String: SQLiteValue]) -> RawPageMatch {
        RawPageMatch(docId: row["doc_id"]!.int, pageIndex: Int(row["page_index"]!.int),
                     bm25: row["score"]!.double, text: row["text"]!.text)
    }
}

private extension SQLiteValue {
    var int: Int64 { if case .int(let v) = self { return v }; fatalError("not int: \(self)") }
    var double: Double {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: fatalError("not double: \(self)")
        }
    }
    var text: String { if case .text(let v) = self { return v }; fatalError("not text: \(self)") }
}
