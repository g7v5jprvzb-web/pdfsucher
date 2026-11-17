import Foundation
@testable import IndexKit
import Synchronization
import Testing
import TestSupport

/// pdf-dubletten: byte-identical PDFs found in one phase-1 run are read once; every copy gets the same result.
@Suite("PDF-Dubletten in Phase 1")
struct DuplicatePDFTests {
    /// Reads a file's bytes as its single page (so any bytes make a "PDF"); "BROKEN…" cannot be read.
    /// With `blockOn`, reading that content waits until the task is cancelled.
    final class Spy: TextSource, Sendable {
        private let calls = Mutex<[String]>([])
        let blockOn: String?
        let started = Atomic(false)
        init(blockOn: String? = nil) { self.blockOn = blockOn }
        var read: [String] { calls.withLock { $0 } }
        func pages(of url: URL) throws -> [PageText] {
            calls.withLock { $0.append(url.path) }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text == blockOn {
                started.store(true, ordering: .relaxed)
                while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.002) }
                throw CancellationError()
            }
            if text.hasPrefix("BROKEN") { throw CocoaError(.fileReadCorruptFile) }
            return [PageText(pageIndex: 0, text: text)]
        }
    }

    struct Env {
        let base: URL, root: URL, store: IndexStore
        func cleanup() { try? FileManager.default.removeItem(at: base) }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func status(_ path: String) throws -> DocumentStatus? {
            try store.documents().first { $0.relativePath == path }?.status
        }
    }

    func makeEnv() throws -> Env {
        let base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        let root = base.appendingPathComponent("pdfs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Env(base: base, root: root, store: try IndexStore(fileURL: base.appendingPathComponent("index.sqlite"), root: root))
    }

    @Test func identicalPDFsInDifferentFoldersAreReadOnce() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try env.write("A/vertrag.pdf", "Mietvertrag Wohnung Lindenstraße")
        try env.write("B/kopie.pdf", "Mietvertrag Wohnung Lindenstraße")
        let spy = Spy()
        let report = try await Indexer(root: env.root, store: env.store, source: spy).update { _ in }
        #expect(spy.read.count == 1, "the copy is not read")
        #expect(report.added == 2)
        let docs = try env.store.documents()
        #expect(docs.map(\.relativePath) == ["A/vertrag.pdf", "B/kopie.pdf"])
        #expect(docs.allSatisfy { $0.status == .ok && $0.pageCount == 1 })
        #expect(try env.store.match("Lindenstraße", in: .words).count == 2, "both are searchable")
        // Unchanged next time: nothing read.
        let next = try await Indexer(root: env.root, store: env.store, source: spy).update { _ in }
        #expect(next.unchanged == 2 && spy.read.count == 1)
    }

    @Test func sameSizeOtherContentIsReadTwice() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try env.write("a.pdf", "Rechnung Nummer 1001")
        try env.write("b.pdf", "Rechnung Nummer 1002")
        let spy = Spy()
        _ = try await Indexer(root: env.root, store: env.store, source: spy).update { _ in }
        #expect(spy.read.count == 2)
        #expect(try env.store.match("1001", in: .words).count == 1)
        #expect(try env.store.match("1002", in: .words).count == 1)
    }

    @Test func identicalUnreadableFilesAreBothErrorsAndReadOnce() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try env.write("x/kaputt.pdf", "BROKEN file")
        try env.write("y/kaputt.pdf", "BROKEN file")
        let spy = Spy()
        let report = try await Indexer(root: env.root, store: env.store, source: spy).update { _ in }
        #expect(spy.read.count == 1)
        #expect(report.failed == ["x/kaputt.pdf", "y/kaputt.pdf"])
        #expect(try env.status("x/kaputt.pdf") == .error && env.status("y/kaputt.pdf") == .error)
    }

    @Test func copiesOfACancelledLeadAreNotStoredAndTheNextRunReadsThem() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let slow = "Langes Dokument das gelesen wird"
        try env.write("1/lang.pdf", slow)
        try env.write("2/lang.pdf", slow)
        let spy = Spy(blockOn: slow)
        let run = Task { try await Indexer(root: env.root, store: env.store, source: spy).update { _ in } }
        while !spy.started.load(ordering: .relaxed) { try await Task.sleep(for: .milliseconds(2)) }
        run.cancel()
        await #expect(throws: CancellationError.self) { _ = try await run.value }
        #expect(try env.store.documents().isEmpty, "neither the lead nor its copy is stored")
        let again = Spy()
        let report = try await Indexer(root: env.root, store: env.store, source: again).update { _ in }
        #expect(report.added == 2 && again.read.count == 1)
        #expect(try env.store.match("Dokument", in: .words).count == 2)
    }

    @Test func progressCountsEveryFileIncludingCopies() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        for folder in ["a", "b", "c"] { try env.write("\(folder)/same.pdf", "Gleicher Inhalt") }
        try env.write("other.pdf", "Anderer Inhalt, länger")
        let seen = Mutex<[IndexProgress]>([])
        let spy = Spy()
        _ = try await Indexer(root: env.root, store: env.store, source: spy).update { p in seen.withLock { $0.append(p) } }
        let values = seen.withLock { $0 }
        #expect(spy.read.count == 2)
        #expect(values.first?.done == 0 && values.first?.total == 4)
        #expect(values.dropFirst().map(\.done) == [1, 2, 3, 4], "one value per finished file")
        #expect(Set(values.compactMap(\.currentFile)) == ["a/same.pdf", "b/same.pdf", "c/same.pdf", "other.pdf"])
    }

    @Test func copiesAreLoggedWithZeroTimeAndCounted() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try env.write("a/same.pdf", "Gleicher Inhalt")
        try env.write("b/same.pdf", "Gleicher Inhalt")
        let logs = env.base.appendingPathComponent("Logs", isDirectory: true)
        let metrics = IndexMetrics(directory: logs)
        metrics.setEnabled(true)
        _ = try await Indexer(root: env.root, store: env.store, source: Spy(), metrics: metrics).update { _ in }
        metrics.flush()
        let files = try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)
        let events = try files.flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n") }
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let fileEvents = events.filter { $0["event"] as? String == "file" }
        #expect(fileEvents.count == 2)
        let copy = try #require(fileEvents.first { $0["dedup"] as? Bool == true })
        #expect(copy["ms"] as? Double == 0)
        let end = try #require(events.first { $0["event"] as? String == "phase_end" && $0["phase"] as? String == "text" })
        #expect(end["dedup"] as? Int == 1)
        #expect(end["hashed"] as? Int == 2)
        #expect(end["hash_ms"] is Double)
    }
}
