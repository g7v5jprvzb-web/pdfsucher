import Testing
import Foundation
import Synchronization
import IndexKit
import TestSupport

/// Sleeps per file so cancellation can land mid-run.
private struct SlowSource: TextSource {
    let delay: TimeInterval
    func pages(of url: URL) throws -> [PageText] {
        Thread.sleep(forTimeInterval: delay)
        return [PageText(pageIndex: 0, text: "langsam \(url.deletingPathExtension().lastPathComponent)")]
    }
}

/// Blocks exactly one call (the `blockedCall`-th, 1-based) until `release()`; all others
/// return at once. Only one cooperative thread is ever parked, so parallel tests cannot
/// starve the pool.
private final class GateSource: TextSource, Sendable {
    private let calls = Mutex(0)
    private let gate = DispatchSemaphore(value: 0)
    private let blockedCall: Int
    init(blockedCall: Int = 2) { self.blockedCall = blockedCall }
    var callCount: Int { calls.withLock { $0 } }
    func release() { gate.signal() }
    func pages(of url: URL) throws -> [PageText] {
        let n = calls.withLock { $0 += 1; return $0 }
        if n == blockedCall { gate.wait() }
        return [PageText(pageIndex: 0, text: "Datei \(url.lastPathComponent)")]
    }
}

/// Counts extractions.
private final class CountingSource: TextSource, Sendable {
    private let calls = Mutex(0)
    var callCount: Int { calls.withLock { $0 } }
    func pages(of url: URL) throws -> [PageText] {
        calls.withLock { $0 += 1 }
        Thread.sleep(forTimeInterval: 0.01)
        return [PageText(pageIndex: 0, text: "Zahl \(url.lastPathComponent)")]
    }
}

private final class ProgressLog: Sendable {
    private let values = Mutex<[IndexProgress]>([])
    func append(_ p: IndexProgress) { values.withLock { $0.append(p) } }
    var all: [IndexProgress] { values.withLock { $0 } }
}

@Suite("Indexer")
struct IndexerTests {
    private let fm = FileManager.default

    private struct Env {
        let root: URL
        let storeURL: URL
        let store: IndexStore
        func cleanup() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    private func makeEnv() throws -> Env {
        let base = try PDFFixtures.tempDirectory()
        let root = base.appendingPathComponent("pdfs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = base.appendingPathComponent("index.sqlite")
        return Env(root: root, storeURL: storeURL, store: try IndexStore(fileURL: storeURL, root: root))
    }

    private func pdf(_ env: Env, _ path: String, _ pages: [String]) throws {
        let url = env.root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PDFFixtures.makePDF(at: url, pages: pages)
    }

    @Test func indexerIncremental() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try pdf(env, "a.pdf", ["Apfel"])
        try pdf(env, "b.pdf", ["Birne"])
        try pdf(env, "sub/c.pdf", ["Cranberry"])
        let indexer = Indexer(root: env.root, store: env.store)

        let first = try await indexer.update { _ in }
        #expect(first == IndexReport(added: 3))
        #expect(try env.store.match("birne", in: .words).count == 1)

        let second = try await indexer.update { _ in }
        #expect(second == IndexReport(unchanged: 3))

        try pdf(env, "a.pdf", ["Aprikose"])
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                             ofItemAtPath: env.root.appendingPathComponent("a.pdf").path)
        try fm.removeItem(at: env.root.appendingPathComponent("b.pdf"))
        try pdf(env, "d.pdf", ["Dattel"])
        let third = try await indexer.update { _ in }
        #expect(third == IndexReport(added: 1, updated: 1, removed: 1, unchanged: 1))
        #expect(try env.store.match("apfel", in: .words).isEmpty)
        #expect(try env.store.match("aprikose", in: .words).count == 1)
        #expect(try env.store.match("birne", in: .words).isEmpty)
        #expect(try env.store.documents().map(\.relativePath) == ["a.pdf", "d.pdf", "sub/c.pdf"])
    }

    @Test func sizeChangeAloneCountsAsUpdate() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try pdf(env, "a.pdf", ["kurz"])
        let url = env.root.appendingPathComponent("a.pdf")
        let indexer = Indexer(root: env.root, store: env.store)
        _ = try await indexer.update { _ in }
        let mtime = try #require(try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        try pdf(env, "a.pdf", ["ein deutlich längerer Text"])
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        #expect(try await indexer.update { _ in } == IndexReport(updated: 1))
    }

    @Test func indexerContinuesAfterBrokenFile() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try pdf(env, "good1.pdf", ["Vertrag eins"])
        try pdf(env, "good2.pdf", ["Vertrag zwei"])
        try Data("not a pdf".utf8).write(to: env.root.appendingPathComponent("bad.pdf"))
        let report = try await Indexer(root: env.root, store: env.store).update { _ in }
        #expect(report.added == 3)
        #expect(report.failed == ["bad.pdf"])
        #expect(try env.store.match("vertrag", in: .words).count == 2)
        let bad = try #require(try env.store.documents().first { $0.relativePath == "bad.pdf" })
        #expect(bad.status == .error)
        #expect(bad.pageCount == 0)
    }

    @Test func brokenFileIsNotRetriedUntilItChanges() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try Data("not a pdf".utf8).write(to: env.root.appendingPathComponent("bad.pdf"))
        let indexer = Indexer(root: env.root, store: env.store)
        _ = try await indexer.update { _ in }
        #expect(try await indexer.update { _ in } == IndexReport(unchanged: 1))
        try pdf(env, "bad.pdf", ["repariert"])
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                             ofItemAtPath: env.root.appendingPathComponent("bad.pdf").path)
        #expect(try await indexer.update { _ in } == IndexReport(updated: 1))
        #expect(try env.store.documents().first?.status == .ok)
    }

    @Test func indexerMarksNoText() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try pdf(env, "empty.pdf", [""])
        let report = try await Indexer(root: env.root, store: env.store).update { _ in }
        #expect(report.noText == ["empty.pdf"])
        #expect(report.added == 1)
        let doc = try #require(try env.store.documents().first)
        #expect(doc.status == .noText)
        #expect(doc.pageCount == 1)
    }

    @Test func indexerReportsProgress() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        for name in ["a", "b", "c"] { try pdf(env, "\(name).pdf", [name]) }
        let log = ProgressLog()
        _ = try await Indexer(root: env.root, store: env.store).update { log.append($0) }
        let values = log.all
        #expect(values.last?.done == 3)
        #expect(values.last?.total == 3)
        #expect(values.allSatisfy { $0.total == 3 && $0.done <= 3 })
        #expect(values.map(\.done) == values.map(\.done).sorted())
        #expect(Set(values.compactMap(\.currentFile)).isSubset(of: ["a.pdf", "b.pdf", "c.pdf"]))
    }

    @Test func noWorkStillReportsFinalProgress() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let log = ProgressLog()
        #expect(try await Indexer(root: env.root, store: env.store).update { log.append($0) } == IndexReport())
        #expect(log.all.last == IndexProgress(done: 0, total: 0, currentFile: nil))
    }

    @Test func writesInBatches() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        for i in 0..<7 { try pdf(env, "f\(i).pdf", ["Datei \(i)"]) }
        let report = try await Indexer(root: env.root, store: env.store, batchSize: 3).update { _ in }
        #expect(report.added == 7)
        #expect(try env.store.documents().count == 7)
        #expect(try env.store.match("datei", in: .words).count == 7)
    }

    @Test(.timeLimit(.minutes(1))) func indexerCancels() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        for i in 0..<40 { try Data("x".utf8).write(to: env.root.appendingPathComponent("f\(i).pdf")) }
        let source = GateSource()
        let indexer = Indexer(root: env.root, store: env.store, source: source, batchSize: 50)
        let (stream, continuation) = AsyncStream<IndexProgress>.makeStream()
        let task = Task { try await indexer.update { continuation.yield($0) } }
        for await p in stream where p.done >= 1 { break }
        task.cancel()
        source.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        continuation.finish()

        let reopened = try IndexStore(fileURL: env.storeURL, root: env.root)
        #expect(reopened.wasRebuilt == false)
        let docs = try reopened.documents()
        // Finished files are written even though the batch was not full.
        #expect(docs.count >= 1)
        #expect(try reopened.allPages().count == docs.count)
        let report = try await Indexer(root: env.root, store: reopened, source: SlowSource(delay: 0)).update { _ in }
        #expect(report.added + report.unchanged == 40)
        #expect(try reopened.documents().count == 40)
    }

    @Test func concurrentUpdatesRunOneAfterAnother() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        for i in 0..<20 { try Data("x".utf8).write(to: env.root.appendingPathComponent("f\(i).pdf")) }
        let source = CountingSource()
        let indexer = Indexer(root: env.root, store: env.store, source: source)
        async let a = indexer.update { _ in }
        async let b = indexer.update { _ in }
        let reports = try await [a, b]
        #expect(source.callCount == 20)
        #expect(reports.contains(IndexReport(added: 20)))
        #expect(reports.contains(IndexReport(unchanged: 20)))
    }

    @Test(.timeLimit(.minutes(1))) func cancelledWaitingUpdateStopsAtOnce() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        for i in 0..<5 { try Data("x".utf8).write(to: env.root.appendingPathComponent("f\(i).pdf")) }
        let source = GateSource()
        let indexer = Indexer(root: env.root, store: env.store, source: source)
        let (stream, continuation) = AsyncStream<IndexProgress>.makeStream()
        let first = Task { try await indexer.update { continuation.yield($0) } }
        for await p in stream where p.done >= 1 { break }   // first run is busy (blocked on the gate)
        let second = Task { try await indexer.update { _ in } }
        try await Task.sleep(for: .milliseconds(100))        // let it queue behind the first
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        source.release()
        #expect(try await first.value.added == 5)
        continuation.finish()
    }

    /// A queued update that is woken and then cancelled must pass the wake-up on,
    /// or the next queued update waits forever.
    @Test(.timeLimit(.minutes(2))) func cancelledWokenWaiterDoesNotStrandTheNext() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try Data("x".utf8).write(to: env.root.appendingPathComponent("f.pdf"))
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<150 {
            try env.store.deleteIndex()
            let source = GateSource(blockedCall: 1)
            let indexer = Indexer(root: env.root, store: env.store, source: source)
            let (stream, continuation) = AsyncStream<IndexProgress>.makeStream()
            let a = Task { try await indexer.update { continuation.yield($0) } }
            for await p in stream where p.total == 1 { break }
            let b = Task { try await indexer.update { _ in } }
            let c = Task { try await indexer.update { _ in } }
            try await Task.sleep(for: .milliseconds(5))
            source.release()
            // Vary when B is cancelled relative to A's hand-over, to hit the woken-then-cancelled window.
            let jitter = Int.random(in: 0...1500, using: &rng)
            if jitter > 0 { try await Task.sleep(for: .microseconds(jitter)) }
            b.cancel()
            _ = try await a.value
            _ = try? await b.value
            // Fail instead of hanging if C is stranded (awaiting `c.value` is not cancellable).
            let finished = Mutex<IndexReport??>(nil)
            Task { let r = try? await c.value; finished.withLock { $0 = .some(r) } }
            var outcome: IndexReport?? = nil
            for _ in 0..<500 where outcome == nil {
                try await Task.sleep(for: .milliseconds(10))
                outcome = finished.withLock { $0 }
            }
            continuation.finish()
            guard let report = outcome ?? nil else {
                Issue.record("queued update stranded after a woken waiter was cancelled")
                return
            }
            #expect(report == IndexReport(unchanged: 1))
        }
    }

    @Test func deleteIndexDuringUpdateIsRefilledCompletely() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        for i in 0..<6 { try Data("x".utf8).write(to: env.root.appendingPathComponent("f\(i).pdf")) }
        let indexer = Indexer(root: env.root, store: env.store, source: SlowSource(delay: 0))
        _ = try await indexer.update { _ in }
        // Change one file so the next run has work, then wipe the index while it runs.
        try Data("xy".utf8).write(to: env.root.appendingPathComponent("f0.pdf"))
        let source = GateSource(blockedCall: 1)
        let busy = Indexer(root: env.root, store: env.store, source: source)
        let (stream, continuation) = AsyncStream<IndexProgress>.makeStream()
        let run = Task { try await busy.update { continuation.yield($0) } }
        for await p in stream where p.total == 1 { break }  // diff done against the full index
        try env.store.deleteIndex()
        source.release()
        _ = try await run.value
        continuation.finish()
        #expect(try env.store.documents().count == 6)
    }

    @Test func progressStartsBeforeFirstFileFinishes() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        for name in ["a", "b"] { try pdf(env, "\(name).pdf", [name]) }
        let log = ProgressLog()
        _ = try await Indexer(root: env.root, store: env.store).update { log.append($0) }
        #expect(log.all.first == IndexProgress(done: 0, total: 2, currentFile: nil))
    }

    @Test func brokenFolderLinkKeepsItsDocuments() async throws {
        let env = try makeEnv()
        let outside = try PDFFixtures.tempDirectory()
        defer { env.cleanup(); try? fm.removeItem(at: outside) }
        try PDFFixtures.makePDF(at: outside.appendingPathComponent("extern.pdf"), pages: ["Festplatte"])
        try fm.createSymbolicLink(atPath: env.root.appendingPathComponent("platte").path, withDestinationPath: outside.path)
        let indexer = Indexer(root: env.root, store: env.store)
        #expect(try await indexer.update { _ in }.added == 1)
        try fm.removeItem(at: outside) // "unmounted"
        #expect(try await indexer.update { _ in }.removed == 0)
        #expect(try env.store.match("festplatte", in: .words).count == 1)
    }

    @Test func corruptIndexDuringUpdateIsRebuiltAndRefilled() async throws {
        let base = try PDFFixtures.tempDirectory()
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("pdfs", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try PDFFixtures.makePDF(at: root.appendingPathComponent("a.pdf"), pages: ["Vertrag"])
        try PDFFixtures.makePDF(at: root.appendingPathComponent("b.pdf"), pages: ["Angebot"])
        let storeURL = base.appendingPathComponent("index.sqlite")
        do {
            let store = try IndexStore(fileURL: storeURL, root: root)
            _ = try await Indexer(root: root, store: store).update { _ in }
        }
        // Closed; now damage the root page of `documents` (header and schema stay intact).
        do {
            let raw = try SQLiteConnection(path: storeURL.path)
            try raw.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            guard case .int(let rootPage)? = try raw.query("SELECT rootpage FROM sqlite_master WHERE name = 'documents'", []).first?["rootpage"],
                  case .int(let pageSize)? = try raw.query("PRAGMA page_size", []).first?["page_size"] else {
                Issue.record("no rootpage"); return
            }
            let handle = try FileHandle(forWritingTo: storeURL)
            try handle.seek(toOffset: UInt64((rootPage - 1) * pageSize))
            try handle.write(contentsOf: Data(repeating: 0x5A, count: Int(pageSize)))
            try handle.close()
        }
        let store = try IndexStore(fileURL: storeURL, root: root)
        let report = try await Indexer(root: root, store: store).update { _ in }
        #expect(store.wasRebuilt)
        #expect(report == IndexReport(added: 2))
        #expect(try store.match("vertrag", in: .words).count == 1)
    }

    @Test func unreadableSubdirectoryKeepsItsDocuments() async throws {
        let env = try makeEnv()
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: env.root.appendingPathComponent("locked").path)
            env.cleanup()
        }
        try pdf(env, "locked/inner.pdf", ["Geheimakte"])
        try pdf(env, "open.pdf", ["offen"])
        let indexer = Indexer(root: env.root, store: env.store)
        _ = try await indexer.update { _ in }
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: env.root.appendingPathComponent("locked").path)
        let report = try await indexer.update { _ in }
        #expect(report.removed == 0)
        #expect(try env.store.match("geheimakte", in: .words).count == 1)
    }

    @Test func unreachableFolderThrowsAndKeepsIndex() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try pdf(env, "a.pdf", ["Vertrag"])
        _ = try await Indexer(root: env.root, store: env.store).update { _ in }
        try fm.removeItem(at: env.root)
        await #expect(throws: (any Error).self) { try await Indexer(root: env.root, store: env.store).update { _ in } }
        #expect(try env.store.match("vertrag", in: .words).count == 1)
    }
}
