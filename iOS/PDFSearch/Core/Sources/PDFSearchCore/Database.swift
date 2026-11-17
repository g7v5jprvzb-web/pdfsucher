import Foundation
import SQLite3

/// A value bound to or read from SQLite.
enum SQLValue: Sendable, Equatable {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

public struct DatabaseError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite \(code): \(message)" }
}

/// One result row, keyed by column name (alias computed columns with `AS`).
struct Row {
    fileprivate var values: [String: SQLValue]

    func int(_ column: String) -> Int64 {
        switch values[column] {
        case .int(let v): v
        case .double(let v): Int64(v)
        case .text(let v): Int64(v) ?? 0
        default: 0
        }
    }

    func double(_ column: String) -> Double {
        switch values[column] {
        case .double(let v): v
        case .int(let v): Double(v)
        default: 0
        }
    }

    func text(_ column: String) -> String {
        switch values[column] {
        case .text(let v): v
        case .int(let v): String(v)
        default: ""
        }
    }

    func blob(_ column: String) -> Data {
        switch values[column] {
        case .blob(let v): v
        case .text(let v): Data(v.utf8)
        default: Data()
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin wrapper around one sqlite3 handle. Not thread-safe: it is owned by the `IndexStore` actor,
/// which serialises every call.
final class Database {
    private let db: OpaquePointer

    init(path: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Datenbank lässt sich nicht öffnen"
            if let handle { sqlite3_close(handle) }
            throw DatabaseError(code: rc, message: message)
        }
        db = handle
        sqlite3_busy_timeout(db, 5000)
    }

    deinit {
        sqlite3_close_v2(db)
    }

    /// Runs one or more statements without binds.
    func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(err)
            throw DatabaseError(code: rc, message: message)
        }
    }

    /// Runs one statement, discards rows, returns the last insert rowid.
    @discardableResult
    func run(_ sql: String, _ binds: [SQLValue] = []) throws -> Int64 {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
        }
        return sqlite3_last_insert_rowid(db)
    }

    func query(_ sql: String, _ binds: [SQLValue] = []) throws -> [Row] {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        let columns = sqlite3_column_count(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
            var values: [String: SQLValue] = [:]
            for i in 0..<columns {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER:
                    values[name] = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT:
                    values[name] = .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(stmt, i))
                    if let ptr = sqlite3_column_text(stmt, i) {
                        values[name] = .text(String(decoding: UnsafeBufferPointer(start: ptr, count: count), as: UTF8.self))
                    } else {
                        values[name] = .text("")
                    }
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(stmt, i))
                    if let ptr = sqlite3_column_blob(stmt, i), count > 0 {
                        values[name] = .blob(Data(bytes: ptr, count: count))
                    } else {
                        values[name] = .blob(Data())
                    }
                default:
                    values[name] = .null
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    /// BEGIN/COMMIT around `body`, ROLLBACK when it throws. Not reentrant.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var changes: Int { Int(sqlite3_changes(db)) }

    // MARK: - Helpers

    private func error(_ rc: Int32) -> DatabaseError {
        DatabaseError(code: rc, message: String(cString: sqlite3_errmsg(db)))
    }

    private func prepare(_ sql: String, _ binds: [SQLValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            throw error(rc)
        }
        let expected = Int(sqlite3_bind_parameter_count(stmt))
        guard expected == binds.count else {
            sqlite3_finalize(stmt)
            throw DatabaseError(code: SQLITE_RANGE, message: "\(expected) Parameter, aber \(binds.count) Werte")
        }
        for (offset, value) in binds.enumerated() {
            let index = Int32(offset + 1)
            let brc: Int32
            switch value {
            case .int(let v):
                brc = sqlite3_bind_int64(stmt, index, v)
            case .double(let v):
                brc = sqlite3_bind_double(stmt, index, v)
            case .text(let v):
                let bytes = Array(v.utf8)
                brc = bytes.withUnsafeBufferPointer { (buffer: UnsafeBufferPointer<UInt8>) -> Int32 in
                    buffer.baseAddress.map {
                        $0.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                            sqlite3_bind_text(stmt, index, $0, Int32(buffer.count), sqliteTransient)
                        }
                    } ?? sqlite3_bind_text(stmt, index, "", 0, sqliteTransient)
                }
            case .blob(let v):
                brc = v.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int32 in
                    if let base = buffer.baseAddress, buffer.count > 0 {
                        return sqlite3_bind_blob(stmt, index, base, Int32(buffer.count), sqliteTransient)
                    }
                    return sqlite3_bind_zeroblob(stmt, index, 0)
                }
            case .null:
                brc = sqlite3_bind_null(stmt, index)
            }
            guard brc == SQLITE_OK else {
                let e = error(brc)
                sqlite3_finalize(stmt)
                throw e
            }
        }
        return stmt
    }
}
