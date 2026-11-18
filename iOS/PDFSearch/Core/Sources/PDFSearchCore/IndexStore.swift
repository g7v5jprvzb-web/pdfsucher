import Foundation

/// One page that matched every search term, before grouping into documents.
struct CandidatePage: Sendable {
    let fileID: Int64
    let folderID: Int64
    let relativePath: String
    let kind: FileKind
    let modified: Double
    let pageCount: Int
    let pageNumber: Int
    let body: String
}

/// What the indexer hands over for one file.
public struct FileEntry: Sendable, Hashable {
    public let relativePath: String
    public let kind: FileKind
    public let size: Int64
    public let modified: Double

    public init(relativePath: String, kind: FileKind, size: Int64, modified: Double) {
        self.relativePath = relativePath
        self.kind = kind
        self.size = size
        self.modified = modified
    }
}

/// The search index: picked folders, their files and the folded text of every page.
///
/// Page text lives in an FTS5 table with the trigram tokenizer, so any part of a word is found
/// ("trag" finds "Vertrag"). If the system SQLite should lack FTS5, a plain table with LIKE is
/// used instead (slower, same results).
public actor IndexStore {
    static let schemaVersion = 1

    private let db: Database
    /// False when FTS5/trigram is unavailable and the plain fallback table is used.
    public nonisolated let usesFullTextIndex: Bool

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try Database(path: databaseURL.path)
        try db.execute("PRAGMA journal_mode=WAL")
        self.usesFullTextIndex = try Self.migrate(db)
        self.db = db
    }

    /// An index that lives only in memory (tests, fallback when the file cannot be opened).
    public init() throws {
        let db = try Database(path: ":memory:")
        self.usesFullTextIndex = try Self.migrate(db)
        self.db = db
    }

    private static func migrate(_ db: Database) throws -> Bool {
        try db.execute("PRAGMA foreign_keys=ON")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS folders(
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                bookmark BLOB NOT NULL,
                added_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS files(
                id INTEGER PRIMARY KEY,
                folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
                rel_path TEXT NOT NULL,
                kind TEXT NOT NULL,
                size INTEGER NOT NULL,
                modified REAL NOT NULL,
                page_count INTEGER NOT NULL,
                state TEXT NOT NULL,
                UNIQUE(folder_id, rel_path)
            );
            """)
        let version = try db.query("SELECT value FROM meta WHERE key = 'schema'").first?.text("value")
        if version == nil {
            try db.run("INSERT INTO meta(key, value) VALUES('schema', ?)", [.text(String(schemaVersion))])
        }
        let existing = try db.query("SELECT sql FROM sqlite_master WHERE name = 'pages'").first?.text("sql")
        if let existing {
            return existing.lowercased().contains("fts5")
        }
        do {
            try db.execute("CREATE VIRTUAL TABLE pages USING fts5(body, file_id UNINDEXED, page_no UNINDEXED, tokenize='trigram')")
            return true
        } catch {
            try db.execute("""
                CREATE TABLE pages(body TEXT NOT NULL, file_id INTEGER NOT NULL, page_no INTEGER NOT NULL);
                CREATE INDEX pages_file ON pages(file_id);
                """)
            return false
        }
    }

    // MARK: - Folders

    public func addFolder(name: String, bookmark: Data) throws -> FolderRecord {
        let now = Date()
        let id = try db.run("INSERT INTO folders(name, bookmark, added_at) VALUES(?, ?, ?)",
                            [.text(name), .blob(bookmark), .double(now.timeIntervalSince1970)])
        return FolderRecord(id: id, name: name, bookmark: bookmark, addedAt: now)
    }

    public func folders() throws -> [FolderRecord] {
        try db.query("SELECT id, name, bookmark, added_at FROM folders ORDER BY name COLLATE NOCASE").map {
            FolderRecord(id: $0.int("id"), name: $0.text("name"), bookmark: $0.blob("bookmark"),
                         addedAt: Date(timeIntervalSince1970: $0.double("added_at")))
        }
    }

    public func updateBookmark(folderID: Int64, bookmark: Data) throws {
        try db.run("UPDATE folders SET bookmark = ? WHERE id = ?", [.blob(bookmark), .int(folderID)])
    }

    public func removeFolder(id: Int64) throws {
        try db.transaction {
            try db.run("DELETE FROM pages WHERE file_id IN (SELECT id FROM files WHERE folder_id = ?)", [.int(id)])
            try db.run("DELETE FROM files WHERE folder_id = ?", [.int(id)])
            try db.run("DELETE FROM folders WHERE id = ?", [.int(id)])
        }
    }

    // MARK: - Files

    public func files(inFolder folderID: Int64) throws -> [StoredFile] {
        try db.query("""
            SELECT id, folder_id, rel_path, kind, size, modified, page_count, state
            FROM files WHERE folder_id = ?
            """, [.int(folderID)]).compactMap(Self.storedFile)
    }

    public func file(id: Int64) throws -> StoredFile? {
        try db.query("""
            SELECT id, folder_id, rel_path, kind, size, modified, page_count, state
            FROM files WHERE id = ?
            """, [.int(id)]).first.flatMap(Self.storedFile)
    }

    /// Every readable file in the scope, for the list shown while the search field is empty.
    public func indexedFiles(scope: SearchScope, kinds: Set<FileKind>) throws -> [StoredFile] {
        guard !kinds.isEmpty else { return [] }
        var conditions = ["state = 'indexed'"]
        var binds: [SQLValue] = []
        if case .folder(let id) = scope {
            conditions.append("folder_id = ?")
            binds.append(.int(id))
        }
        if kinds.count < FileKind.allCases.count {
            let list = kinds.map { "'\($0.rawValue)'" }.sorted().joined(separator: ",")
            conditions.append("kind IN (\(list))")
        }
        return try db.query("""
            SELECT id, folder_id, rel_path, kind, size, modified, page_count, state
            FROM files WHERE \(conditions.joined(separator: " AND "))
            """, binds).compactMap(Self.storedFile)
    }

    private static func storedFile(_ row: Row) -> StoredFile? {
        guard let kind = FileKind(rawValue: row.text("kind")),
              let state = FileState(rawValue: row.text("state")) else { return nil }
        return StoredFile(id: row.int("id"), folderID: row.int("folder_id"), relativePath: row.text("rel_path"),
                          kind: kind, size: row.int("size"), modified: row.double("modified"),
                          pageCount: Int(row.int("page_count")), state: state)
    }

    /// Inserts or replaces a file and its pages. `pages` holds the raw text of each page in order;
    /// it is folded here.
    @discardableResult
    public func store(_ entry: FileEntry, folderID: Int64, pages: [String], state: FileState) throws -> Int64 {
        let folded = pages.map(TextFolding.fold)
        return try db.transaction {
            if let old = try db.query("SELECT id FROM files WHERE folder_id = ? AND rel_path = ?",
                                      [.int(folderID), .text(entry.relativePath)]).first?.int("id") {
                try db.run("DELETE FROM pages WHERE file_id = ?", [.int(old)])
                try db.run("DELETE FROM files WHERE id = ?", [.int(old)])
            }
            let id = try db.run("""
                INSERT INTO files(folder_id, rel_path, kind, size, modified, page_count, state)
                VALUES(?, ?, ?, ?, ?, ?, ?)
                """, [.int(folderID), .text(entry.relativePath), .text(entry.kind.rawValue), .int(entry.size),
                      .double(entry.modified), .int(Int64(pages.count)), .text(state.rawValue)])
            for (index, body) in folded.enumerated() where !body.isEmpty {
                try db.run("INSERT INTO pages(body, file_id, page_no) VALUES(?, ?, ?)",
                           [.text(body), .int(id), .int(Int64(index + 1))])
            }
            return id
        }
    }

    public func removeFiles(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            for id in ids {
                try db.run("DELETE FROM pages WHERE file_id = ?", [.int(id)])
                try db.run("DELETE FROM files WHERE id = ?", [.int(id)])
            }
        }
    }

    public func stats(folderID: Int64) throws -> FolderStats {
        var stats = FolderStats()
        for row in try db.query("SELECT kind, state, COUNT(*) AS n FROM files WHERE folder_id = ? GROUP BY kind, state", [.int(folderID)]) {
            let n = Int(row.int("n"))
            switch FileState(rawValue: row.text("state")) {
            case .notDownloaded: stats.notDownloaded += n
            case .failed: stats.failed += n
            default: break
            }
            switch FileKind(rawValue: row.text("kind")) {
            case .pdf: stats.pdfCount += n
            case .jpeg: stats.jpegCount += n
            case nil: break
            }
        }
        return stats
    }

    // MARK: - Search

    /// Pages containing every term (terms already folded).
    func candidatePages(terms: [String], scope: SearchScope, kinds: Set<FileKind>) throws -> [CandidatePage] {
        guard !terms.isEmpty, !kinds.isEmpty else { return [] }
        var conditions: [String] = []
        var binds: [SQLValue] = []

        let ftsTerms = usesFullTextIndex ? terms.filter { $0.unicodeScalars.count >= 3 } : []
        if !ftsTerms.isEmpty {
            conditions.append("pages MATCH ?")
            binds.append(.text(ftsTerms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")))
        }
        for term in terms where !ftsTerms.contains(term) {
            conditions.append("pages.body LIKE ? ESCAPE '\\'")
            binds.append(.text("%" + Self.escapeLike(term) + "%"))
        }
        if case .folder(let id) = scope {
            conditions.append("files.folder_id = ?")
            binds.append(.int(id))
        }
        if kinds.count < FileKind.allCases.count {
            let list = kinds.map { "'\($0.rawValue)'" }.sorted().joined(separator: ",")
            conditions.append("files.kind IN (\(list))")
        }
        conditions.append("files.state = 'indexed'")

        let sql = """
            SELECT files.id AS fid, files.folder_id AS folder_id, files.rel_path AS rel_path, files.kind AS kind,
                   files.modified AS modified, files.page_count AS page_count,
                   pages.page_no AS page_no, pages.body AS body
            FROM pages JOIN files ON files.id = pages.file_id
            WHERE \(conditions.joined(separator: " AND "))
            """
        return try db.query(sql, binds).compactMap { row in
            guard let kind = FileKind(rawValue: row.text("kind")) else { return nil }
            return CandidatePage(fileID: row.int("fid"), folderID: row.int("folder_id"), relativePath: row.text("rel_path"),
                                 kind: kind, modified: row.double("modified"), pageCount: Int(row.int("page_count")),
                                 pageNumber: Int(row.int("page_no")), body: row.text("body"))
        }
    }

    private static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
