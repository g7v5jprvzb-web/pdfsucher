import Testing
import Foundation
import TestSupport
@testable import IndexKit

@Suite("SQLiteConnection review fixes")
struct SQLiteReviewFixTests {
    /// A second connection must wait for a short write lock instead of failing with SQLITE_BUSY.
    @Test func waitsForLockHeldByOtherConnection() throws {
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("busy.sqlite").path
        let a = try SQLiteConnection(path: path)
        try a.execute("CREATE TABLE r(x INTEGER)")
        let b = try SQLiteConnection(path: path)
        try a.execute("BEGIN IMMEDIATE")
        try a.run("INSERT INTO r VALUES (?)", [.int(1)])
        // Release from a GCD thread, independent of the Swift concurrency pool.
        let released = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) {
            try? a.execute("COMMIT")
            released.signal()
        }
        try b.run("INSERT INTO r VALUES (?)", [.int(2)])
        released.wait()
        #expect(try b.query("SELECT count(*) AS n FROM r", [])[0]["n"] == .int(2))
    }

    @Test func textWithNulRoundTrips() throws {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("CREATE TABLE t(v TEXT)")
        let value = "a\u{0}bü"
        try db.run("INSERT INTO t VALUES (?)", [.text(value)])
        let rows = try db.query("SELECT v, length(CAST(v AS BLOB)) AS n FROM t", [])
        #expect(rows[0]["n"] == .int(Int64(value.utf8.count)))
        #expect(rows[0]["v"] == .text(value))
    }
}
