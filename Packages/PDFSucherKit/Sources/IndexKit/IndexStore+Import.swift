// IndexStore+Import.swift — 1.4.0 P1: a parent folder takes over what the indexes of its subfolders already hold
import Foundation

extension IndexStore {
    /// An index file on disk and the folder it belongs to (`meta.folder_path`).
    public struct ChildIndex: Sendable, Equatable {
        public let fileURL: URL
        public let folderPath: String
    }

    /// What `importChild` took over.
    public struct ImportResult: Sendable, Equatable {
        public var documents = 0, pages = 0
        /// Word/PowerPoint documents taken over without their layout (another renderer recorded): they wait for layout.
        public var layoutDropped = 0
        public init() {}
    }

    /// Index files in `directory` (other than `excluding`) of folders strictly below `root`, shallowest first, with a
    /// schema this version can read (3 to 5). Files that cannot be read are skipped.
    public static func childIndexes(of root: URL, in directory: URL, excluding: URL) -> [ChildIndex] {
        let parent = root.standardizedFileURL.path
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var found: [ChildIndex] = []
        for file in files where file.pathExtension == "sqlite" && file.standardizedFileURL != excluding.standardizedFileURL {
            guard let db = try? SQLiteConnection(path: file.path),
                  let rows = try? db.query("SELECT key, value FROM meta WHERE key IN ('folder_path', 'schema_version')", []) else { continue }
            var meta: [String: String] = [:]
            for row in rows { if case .text(let k)? = row["key"], case .text(let v)? = row["value"] { meta[k] = v } }
            guard let folder = meta["folder_path"], ["3", "4", "5", "6"].contains(meta["schema_version"] ?? ""),
                  folder.hasPrefix(parent + "/") else { continue }
            found.append(ChildIndex(fileURL: file, folderPath: folder))
        }
        return found.sorted { ($0.folderPath.split(separator: "/").count, $0.folderPath) < ($1.folderPath.split(separator: "/").count, $1.folderPath) }
    }

    /// Copies the documents of `child` (the index of folder `child.folderPath`, below this index's root) that this index
    /// does not hold yet, with their pages, OCR word boxes and layout state, in one transaction; their paths get the
    /// folder's path below the root as prefix. Phase 1 then finds them unchanged (same size and date) or reads them again.
    /// Pages arrive like phase-1 pages (`trigram_pending` for text pages). Word/PowerPoint layouts are kept only when the
    /// child recorded the same renderer as this index expects (or this index expects none yet: it adopts the child's);
    /// otherwise those documents come without pages and wait for layout.
    public func importChild(_ child: ChildIndex) throws -> ImportResult {
        let prefix = String(child.folderPath.dropFirst(root.standardizedFileURL.path.count + 1)).precomposedStringWithCanonicalMapping + "/"
        return try batchOutsideTransaction { db in
            try db.run("ATTACH DATABASE ? AS child", [.text(child.fileURL.path)])
            defer { _ = try? db.run("DETACH DATABASE child", []) }
            return try db.transaction {
                var result = ImportResult()
                // Once per child index: what it held is in here now; later sessions leave it alone (it is an orphan).
                let mark = "imported:" + child.fileURL.lastPathComponent
                guard try db.query("SELECT 1 FROM main.meta WHERE key = ?", [.text(mark)]).isEmpty else { return result }
                try db.run("INSERT INTO main.meta(key, value) VALUES (?, ?)", [.text(mark), .text(child.folderPath)])
                // Layout renderer records per kind: keep layouts only where they agree.
                var keepLayout: [String: Bool] = [:]
                for kind in ["word", "powerpoint"] {
                    let key = "layout.expected.\(kind)"
                    let mine = try db.query("SELECT value FROM main.meta WHERE key = ?", [.text(key)]).first?.optionalText("value")
                    let theirs = try db.query("SELECT value FROM child.meta WHERE key = ?", [.text(key)]).first?.optionalText("value")
                    if mine == nil, let theirs {
                        try db.run("INSERT INTO main.meta(key, value) VALUES (?, ?)", [.text(key), .text(theirs)])
                        keepLayout[kind] = true
                    } else {
                        keepLayout[kind] = mine != nil && mine == theirs
                    }
                }
                let before = try db.query("SELECT coalesce(max(id), 0) AS m FROM main.documents", []).first?.int("m") ?? 0
                try db.run("""
                    INSERT INTO main.documents(path, file_size, modified_at, page_count, status, kind, renderer, layout_version, needs_layout)
                    SELECT ?1 || c.path, c.file_size, c.modified_at, c.page_count, c.status, c.kind, c.renderer, c.layout_version, c.needs_layout
                    FROM child.documents c
                    WHERE NOT EXISTS (SELECT 1 FROM main.documents d WHERE d.path = ?1 || c.path)
                    ORDER BY c.id
                    """, [.text(prefix)])
                try db.execute("DROP TABLE IF EXISTS temp.import_map; CREATE TEMP TABLE import_map(old INTEGER PRIMARY KEY, new INTEGER NOT NULL, kind TEXT NOT NULL)")
                try db.run("""
                    INSERT INTO temp.import_map(old, new, kind)
                    SELECT c.id, d.id, d.kind FROM child.documents c JOIN main.documents d ON d.path = ?1 || c.path WHERE d.id > ?2
                    """, [.text(prefix), .int(before)])
                // Office documents of another renderer: no pages, waiting for layout (like `upsertAwaitingLayout`).
                for (kind, keep) in keepLayout where !keep {
                    try db.run("""
                        UPDATE main.documents SET needs_layout = 1, page_count = 0, status = 'no_text', renderer = NULL, layout_version = NULL
                        WHERE id IN (SELECT new FROM temp.import_map WHERE kind = ?)
                        """, [.text(kind)])
                    result.layoutDropped += db.changes
                    try db.run("DELETE FROM temp.import_map WHERE kind = ?", [.text(kind)])
                }
                result.documents = Int(try db.query("SELECT count(*) AS n FROM temp.import_map", []).first?.int("n") ?? 0)
                try db.run("""
                    INSERT INTO main.page_text(doc_id, page_index, text, source, needs_ocr)
                    SELECT m.new, p.page_index, p.text, p.source, p.needs_ocr
                    FROM child.page_text p JOIN temp.import_map m ON m.old = p.doc_id ORDER BY p.id
                    """, [])
                result.pages = db.changes
                try db.run("""
                    INSERT INTO main.ocr_words(page_text_id, start_utf16, length_utf16, x, y, w, h)
                    SELECT np.id, w.start_utf16, w.length_utf16, w.x, w.y, w.w, w.h
                    FROM child.ocr_words w
                    JOIN child.page_text op ON op.id = w.page_text_id
                    JOIN temp.import_map m ON m.old = op.doc_id
                    JOIN main.page_text np ON np.doc_id = m.new AND np.page_index = op.page_index
                    ORDER BY w.rowid
                    """, [])
                try db.execute("DROP TABLE temp.import_map")
                return result
            }
        }
    }
}
