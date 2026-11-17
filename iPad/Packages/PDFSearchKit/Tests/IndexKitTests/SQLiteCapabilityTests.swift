import Testing
import Foundation
import SQLite3
@testable import IndexKit

@Suite("SQLite capability")
struct SQLiteCapabilityTests {
    @Test func fts5Available() throws {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("CREATE VIRTUAL TABLE t USING fts5(text)")
        _ = try db.run("INSERT INTO t(text) VALUES (?)", [.text("hello world")])
        let rows = try db.query("SELECT text FROM t WHERE t MATCH ?", [.text("hello")])
        #expect(rows.count == 1)
    }

    @Test func trigramWithDiacriticsAvailable() throws {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("CREATE VIRTUAL TABLE t USING fts5(text, tokenize='trigram case_sensitive 0 remove_diacritics 1')")
        _ = try db.run("INSERT INTO t(text) VALUES (?)", [.text("Vertragsänderung")])
        let rows = try db.query("SELECT text FROM t WHERE t MATCH ?", [.text("anderung")])
        #expect(rows.count == 1)
    }

    @Test func recordsLinkedVersion() {
        let version = String(cString: sqlite3_libversion())
        let fts5 = sqlite3_compileoption_used("ENABLE_FTS5") != 0
        print("LINKED SQLITE \(version) ENABLE_FTS5=\(fts5)")
        #expect(!version.isEmpty)
    }
}

@Suite("SQLiteConnection")
struct SQLiteConnectionTests {
    @Test func bindsAndReadsAllValueKinds() throws {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("CREATE TABLE v(i INTEGER, d REAL, t TEXT, n TEXT)")
        _ = try db.run("INSERT INTO v VALUES (?,?,?,?)",
                       [.int(42), .double(1.5), .text("grüß 'dich'"), .null])
        let rows = try db.query("SELECT i,d,t,n FROM v", [])
        #expect(rows.count == 1)
        #expect(rows[0]["i"] == .int(42))
        #expect(rows[0]["d"] == .double(1.5))
        #expect(rows[0]["t"] == .text("grüß 'dich'"))
        #expect(rows[0]["n"] == .null)
    }

    @Test func runReturnsLastRowID() throws {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("CREATE TABLE r(id INTEGER PRIMARY KEY, x TEXT)")
        #expect(try db.run("INSERT INTO r(x) VALUES (?)", [.text("a")]) == 1)
        #expect(try db.run("INSERT INTO r(x) VALUES (?)", [.text("b")]) == 2)
    }

    @Test func transactionCommitsOnSuccess() throws {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("CREATE TABLE r(x INTEGER)")
        let result: Int = try db.transaction {
            _ = try db.run("INSERT INTO r VALUES (?)", [.int(1)])
            _ = try db.run("INSERT INTO r VALUES (?)", [.int(2)])
            return 7
        }
        #expect(result == 7)
        #expect(try db.query("SELECT x FROM r", []).count == 2)
    }

    struct Boom: Error {}

    @Test func transactionRollsBackOnThrow() throws {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("CREATE TABLE r(x INTEGER)")
        #expect(throws: Boom.self) {
            try db.transaction {
                _ = try db.run("INSERT INTO r VALUES (?)", [.int(1)])
                throw Boom()
            }
        }
        #expect(try db.query("SELECT x FROM r", []).isEmpty)
        // connection still usable, no dangling transaction
        try db.transaction { _ = try db.run("INSERT INTO r VALUES (?)", [.int(3)]) }
        #expect(try db.query("SELECT x FROM r", []).count == 1)
    }

    @Test func invalidSQLThrowsSQLiteError() throws {
        let db = try SQLiteConnection(path: ":memory:")
        do {
            try db.execute("THIS IS NOT SQL")
            Issue.record("expected throw")
        } catch let e as SQLiteError {
            #expect(e.code != 0)
            #expect(!e.message.isEmpty)
            #expect(e.description.contains(e.message))
        }
    }

    @Test func foreignKeysAndWALEnabled() throws {
        let db = try SQLiteConnection(path: ":memory:")
        #expect(try db.query("PRAGMA foreign_keys", [])[0].values.first == .int(1))
        let path = NSTemporaryDirectory() + "sqlitewal-\(UUID().uuidString).db"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let file = try SQLiteConnection(path: path)
        #expect(try file.query("PRAGMA journal_mode", [])[0].values.first == .text("wal"))
    }

    @Test func concurrentUseIsSerialised() async throws {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("CREATE TABLE r(x INTEGER)")
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<50 {
                g.addTask { _ = try? db.transaction { _ = try db.run("INSERT INTO r VALUES (?)", [.int(Int64(i))]) } }
            }
        }
        #expect(try db.query("SELECT count(*) AS c FROM r", [])[0]["c"] == .int(50))
    }
}

@Suite("SQLiteConnection robustness")
struct SQLiteRobustnessTests {
    struct Boom: Error {}

    @Test func openingNonDatabaseFileThrowsNotADBWithoutCrash() throws {
        let path = NSTemporaryDirectory() + "notadb-\(UUID().uuidString).db"
        try Data("not a database".utf8).write(to: URL(fileURLWithPath: path))
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        do {
            _ = try SQLiteConnection(path: path)
            Issue.record("expected throw")
        } catch let e as SQLiteError {
            #expect(e.code == 26)
        }
    }

    @Test func nestedFailureCaughtByOuterIsRolledBackOnly() throws {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("CREATE TABLE r(x INTEGER)")
        try db.transaction {
            _ = try db.run("INSERT INTO r VALUES (?)", [.int(1)])
            do {
                try db.transaction {
                    _ = try db.run("INSERT INTO r VALUES (?)", [.int(99)])
                    throw Boom()
                }
            } catch is Boom {}
            _ = try db.run("INSERT INTO r VALUES (?)", [.int(2)])
        }
        let xs = try db.query("SELECT x FROM r ORDER BY x", []).map { $0["x"] }
        #expect(xs == [.int(1), .int(2)])
    }

    @Test func innerSuccessThenOuterFailureRollsBackEverything() throws {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("CREATE TABLE r(x INTEGER)")
        #expect(throws: Boom.self) {
            try db.transaction {
                try db.transaction { _ = try db.run("INSERT INTO r VALUES (?)", [.int(1)]) }
                throw Boom()
            }
        }
        #expect(try db.query("SELECT x FROM r", []).isEmpty)
    }

    @Test func connectionIsAutocommitAfterBodyThrowAndNewTransactionWorks() throws {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("CREATE TABLE r(x INTEGER)")
        #expect(throws: Boom.self) { try db.transaction { throw Boom() } }
        // a fresh BEGIN would fail with "within a transaction" if one were still open
        try db.transaction { _ = try db.run("INSERT INTO r VALUES (?)", [.int(1)]) }
        #expect(try db.query("SELECT count(*) AS c FROM r", [])[0]["c"] == .int(1))
    }

    @Test func bodyThatEndsTransactionItselfStillReportsBodyError() throws {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("CREATE TABLE r(x INTEGER)")
        #expect(throws: Boom.self) {
            try db.transaction {
                try db.execute("ROLLBACK")   // our own ROLLBACK will fail, but state is autocommit
                throw Boom()
            }
        }
        try db.transaction { _ = try db.run("INSERT INTO r VALUES (?)", [.int(1)]) }
    }

    @Test func blobColumnThrows() throws {
        let db = try SQLiteConnection(path: ":memory:")
        #expect(throws: SQLiteError.self) { try db.query("SELECT x'01' AS b", []) }
    }

    @Test func duplicateColumnNamesThrow() throws {
        let db = try SQLiteConnection(path: ":memory:")
        #expect(throws: SQLiteError.self) { try db.query("SELECT 1 AS a, 2 AS a", []) }
    }

    @Test func bindCountMismatchThrows() throws {
        let db = try SQLiteConnection(path: ":memory:")
        #expect(throws: SQLiteError.self) { try db.query("SELECT ? AS a, ? AS b", [.int(1)]) }
        #expect(throws: SQLiteError.self) { try db.query("SELECT ? AS a", [.int(1), .int(2)]) }
        #expect(throws: SQLiteError.self) { try db.run("SELECT 1", [.int(1)]) }
    }

    @Test func multipleStatementsRejectedInQueryAndRunButNotExecute() throws {
        let db = try SQLiteConnection(path: ":memory:")
        #expect(throws: SQLiteError.self) { try db.query("SELECT 1 AS a; SELECT 2 AS a", []) }
        #expect(throws: SQLiteError.self) { try db.run("CREATE TABLE a(x); CREATE TABLE b(x)", []) }
        #expect(try db.query("SELECT 1 AS a; ", []).count == 1)
        try db.execute("CREATE TABLE c(x); CREATE TABLE d(x)")
    }
}
