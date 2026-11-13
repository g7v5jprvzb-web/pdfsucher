import Foundation
import SQLite3
import Synchronization

public enum SQLiteValue: Sendable, Equatable {
    case int(Int64)
    case double(Double)
    case text(String)
    case null
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }
    public var description: String { "SQLite error \(code): \(message)" }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin, thread-safe wrapper around one sqlite3 handle.
///
/// Locking design: two layers with different jobs.
/// - `state` (a non-reentrant `Mutex`) owns the raw handle and is held only for the duration
///   of a single sqlite call, never across user code. It makes each call atomic.
/// - `gate` (an `NSRecursiveLock`) is taken by every public entry point and gives
///   `transaction` exclusivity for its whole body: other threads wait until COMMIT/ROLLBACK,
///   while the owning thread can re-enter `run/query/execute` (and nested `transaction`)
///   from inside the body without deadlocking.
/// Consequence: do NOT hand connection work to another thread (e.g. `DispatchQueue.sync`,
/// awaiting a task that uses this connection) from inside a transaction body and wait for it;
/// that thread blocks on `gate`, which the body's thread holds, and it deadlocks.
///
/// Keep transaction bodies to SQL only (no PDF parsing): every other caller, including
/// searches, waits on `gate` until the transaction ends.
/// Opened NOMUTEX because all access is serialised here; busy timeout 5 s for other connections.
/// Result rows are dictionaries: duplicate column names in one result are an error.
/// `query`/`run` accept exactly one statement; `execute` accepts several.
public final class SQLiteConnection: @unchecked Sendable {
    private struct Handle: @unchecked Sendable { var db: OpaquePointer? }

    private let state: Mutex<Handle>
    private let gate = NSRecursiveLock()
    private var transactionDepth = 0   // guarded by `gate`

    public init(path: String) throws {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            if let db { sqlite3_close(db) }
            throw SQLiteError(code: rc, message: message)
        }
        // Configure on the raw handle BEFORE `state` is assigned: a throwing init then never
        // runs deinit, so the handle is closed exactly once (here).
        // Wait up to 5 s for locks held by other connections instead of failing with SQLITE_BUSY
        // (callers must never treat BUSY as a corrupt index).
        sqlite3_busy_timeout(db, 5000)
        do {
            try Self.exec(db, "PRAGMA journal_mode=WAL")
            try Self.exec(db, "PRAGMA foreign_keys=ON")
        } catch {
            sqlite3_close(db)
            throw error
        }
        state = Mutex(Handle(db: db))
    }

    deinit {
        state.withLock { h in
            if let db = h.db { sqlite3_close_v2(db) }
            h.db = nil
        }
    }

    public func execute(_ sql: String) throws {
        gate.lock(); defer { gate.unlock() }
        try state.withLock { h in try Self.exec(h.db, sql) }
    }

    public func query(_ sql: String, _ binds: [SQLiteValue]) throws -> [[String: SQLiteValue]] {
        var rows: [[String: SQLiteValue]] = []
        try queryEach(sql, binds) { rows.append($0); return true }
        return rows
    }

    /// Steps through the rows one by one; `body` returns false to stop early. The connection stays locked
    /// until it returns (as for `query`), so `body` must not use this connection; a few milliseconds of work
    /// per call (checking a batch of pages) only delay other readers of this connection.
    public func queryEach(_ sql: String, _ binds: [SQLiteValue], _ body: ([String: SQLiteValue]) throws -> Bool) throws {
        gate.lock(); defer { gate.unlock() }
        try state.withLock { h in
            let stmt = try Self.prepare(h.db, sql, binds)
            defer { sqlite3_finalize(stmt) }
            let columns = sqlite3_column_count(stmt)
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw Self.error(h.db, rc) }
                var row: [String: SQLiteValue] = [:]
                for i in 0..<columns {
                    guard let namePtr = sqlite3_column_name(stmt, i) else {
                        throw SQLiteError(code: SQLITE_NOMEM, message: "column name unavailable")
                    }
                    let name = String(cString: namePtr)
                    guard row[name] == nil else {
                        throw SQLiteError(code: SQLITE_MISUSE, message: "duplicate column name '\(name)' in result")
                    }
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, i))
                    case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, i))
                    case SQLITE_TEXT:
                        guard let t = sqlite3_column_text(stmt, i) else {
                            throw SQLiteError(code: SQLITE_NOMEM, message: "text column '\(name)' unavailable")
                        }
                        // Explicit byte length: text may contain NUL characters.
                        let byteCount = Int(sqlite3_column_bytes(stmt, i))
                        row[name] = .text(String(decoding: UnsafeBufferPointer(start: t, count: byteCount), as: UTF8.self))
                    case SQLITE_NULL: row[name] = .null
                    default:
                        throw SQLiteError(code: SQLITE_MISMATCH, message: "unsupported BLOB value in column '\(name)'")
                    }
                }
                guard try body(row) else { break }
            }
        }
    }

    /// Executes a single statement (discarding any rows) and returns `sqlite3_last_insert_rowid`.
    @discardableResult
    public func run(_ sql: String, _ binds: [SQLiteValue]) throws -> Int64 {
        gate.lock(); defer { gate.unlock() }
        return try state.withLock { h in
            let stmt = try Self.prepare(h.db, sql, binds)
            defer { sqlite3_finalize(stmt) }
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw Self.error(h.db, rc) }
            }
            return sqlite3_last_insert_rowid(h.db)
        }
    }

    /// BEGIN/COMMIT around `body`; ROLLBACK if it throws. Exclusive for the whole body.
    /// `run/query/execute` may be called from inside `body`. A nested call uses a SAVEPOINT,
    /// so a failure the outer body catches rolls back only the inner work.
    /// If the rollback itself fails and the transaction is still open, the thrown error
    /// names both the body error and the rollback error.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        gate.lock(); defer { gate.unlock() }
        let nested = transactionDepth > 0
        let sp = "pdfsucher_sp\(transactionDepth)"
        try execute(nested ? "SAVEPOINT \(sp)" : "BEGIN")
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        do {
            let result = try body()
            try execute(nested ? "RELEASE \(sp)" : "COMMIT")
            return result
        } catch {
            var rollbackError: Error?
            do {
                if nested {
                    try execute("ROLLBACK TO \(sp)")
                    try execute("RELEASE \(sp)")
                } else {
                    try execute("ROLLBACK")
                }
            } catch let e { rollbackError = e }
            // Outer: failure is only harmless if SQLite is no longer in a transaction
            // (e.g. it rolled back by itself). Nested: any rollback failure is surfaced.
            if let rollbackError, nested || !isAutocommit {
                throw SQLiteError(code: (rollbackError as? SQLiteError)?.code ?? SQLITE_ERROR,
                                  message: "transaction body failed (\(error)); rollback also failed (\(rollbackError))")
            }
            throw error
        }
    }

    private var isAutocommit: Bool {
        state.withLock { h in sqlite3_get_autocommit(h.db) != 0 }
    }

    // MARK: - Helpers (called with the Mutex held)

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg)
        }
    }

    private static func error(_ db: OpaquePointer?, _ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db)))
    }

    /// Prepares exactly one statement and binds `binds` (count must match the parameters).
    private static func prepare(_ db: OpaquePointer?, _ sql: String, _ binds: [SQLiteValue]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        var tailIsStatement = false
        var tailError: Int32 = SQLITE_OK
        let rc = sql.withCString { cstr -> Int32 in
            var tail: UnsafePointer<CChar>?
            let rc = sqlite3_prepare_v2(db, cstr, -1, &stmt, &tail)
            if rc == SQLITE_OK, let tail {
                var rest: OpaquePointer?
                let trc = sqlite3_prepare_v2(db, tail, -1, &rest, nil)
                if trc != SQLITE_OK { tailError = trc } else if rest != nil { tailIsStatement = true }
                sqlite3_finalize(rest)
            }
            return rc
        }
        guard rc == SQLITE_OK else {
            sqlite3_finalize(stmt)
            throw error(db, rc)
        }
        if tailError != SQLITE_OK || tailIsStatement {
            sqlite3_finalize(stmt)
            throw SQLiteError(code: SQLITE_MISUSE, message: "multiple statements are not allowed here (use execute)")
        }
        guard stmt != nil else { throw SQLiteError(code: SQLITE_MISUSE, message: "empty SQL statement") }
        let expected = Int(sqlite3_bind_parameter_count(stmt))
        guard expected == binds.count else {
            sqlite3_finalize(stmt)
            throw SQLiteError(code: SQLITE_RANGE, message: "statement has \(expected) parameters but \(binds.count) binds were given")
        }
        for (i, value) in binds.enumerated() {
            let idx = Int32(i + 1)
            let brc: Int32
            switch value {
            case .int(let v): brc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): brc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v):
                // Explicit byte length: text may contain NUL characters.
                var utf8 = Array(v.utf8)
                if utf8.isEmpty { utf8 = [0] } // non-null pointer for the empty string
                brc = utf8.withUnsafeBufferPointer { buf in
                    buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                        sqlite3_bind_text(stmt, idx, $0, Int32(v.utf8.count), sqliteTransient)
                    }
                }
            case .null: brc = sqlite3_bind_null(stmt, idx)
            }
            guard brc == SQLITE_OK else {
                let e = error(db, brc)
                sqlite3_finalize(stmt)
                throw e
            }
        }
        return stmt
    }
}
