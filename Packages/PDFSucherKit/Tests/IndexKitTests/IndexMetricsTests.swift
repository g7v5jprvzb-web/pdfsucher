import Foundation
import IndexKit
import Testing
import TestSupport

/// 1.3.9: the measurement log of the indexing — off writes nothing, on writes JSON lines without plain paths.
@Suite("Measurement log")
struct IndexMetricsTests {
    struct Env {
        let base: URL, root: URL, logs: URL, pdf: URL
        let store: IndexStore
        let metrics: IndexMetrics
        func cleanup() { try? FileManager.default.removeItem(at: base) }
        /// Every file's text and its lines as objects.
        func read() throws -> (raw: String, events: [[String: Any]]) {
            metrics.flush()
            let files = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? []
            let raw = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
            let events = try raw.split(separator: "\n").map {
                try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
            return (raw, events)
        }
    }

    func makeEnv() throws -> Env {
        let base = try PDFFixtures.tempDirectory()
        let root = base.appendingPathComponent("Kunde Müller", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pdf = root.appendingPathComponent("Geheimvertrag.pdf")
        try PDFFixtures.makePDF(at: pdf, pages: ["Vertraulicher Inhalt", "Seite zwei"])
        let logs = base.appendingPathComponent("Logs", isDirectory: true)
        return Env(base: base, root: root, logs: logs, pdf: pdf,
                   store: try IndexStore(fileURL: base.appendingPathComponent("index.sqlite"), root: root),
                   metrics: IndexMetrics(directory: logs))
    }

    @Test func offWritesNoFile() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        _ = try await Indexer(root: env.root, store: env.store, metrics: env.metrics).update { _ in }
        env.metrics.log("test", ["x": 1])
        env.metrics.flush()
        #expect(!FileManager.default.fileExists(atPath: env.logs.path))
    }

    @Test func onWritesJSONLinesWithoutPlainPathsOrText() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        env.metrics.setEnabled(true)
        _ = try await IndexMetrics.$run.withValue(7) {
            try await Indexer(root: env.root, store: env.store, metrics: env.metrics).update { _ in }
        }
        let (raw, events) = try env.read()
        for secret in ["Geheimvertrag", "Müller", "Vertraulich", env.root.path, "/Users/", "/var/"] {
            #expect(!raw.contains(secret), "\(secret) must not be logged")
        }
        let names = events.compactMap { $0["event"] as? String }
        for name in ["logging_on", "scan", "diff", "file", "db_batch", "phase_end"] { #expect(names.contains(name)) }
        for event in events {
            #expect((event["ts"] as? String)?.count ?? 0 >= 23)
            #expect(event["run"] is Int)
        }
        let file = try #require(events.first { $0["event"] as? String == "file" })
        #expect(file["run"] as? Int == 7)
        #expect(file["ext"] as? String == "pdf")
        #expect(file["pages"] as? Int == 2)
        #expect((file["file"] as? String)?.count == 12)
        #expect(file["source"] as? String == IndexMetrics.hash(env.root))
        let day = String(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)).prefix(10))
        #expect(FileManager.default.fileExists(atPath: env.logs.appendingPathComponent("index-metrics-\(day).jsonl").path))
    }

    @Test func aFileReadAgainInTheSessionIsReported() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        env.metrics.setEnabled(true)
        let indexer = Indexer(root: env.root, store: env.store, metrics: env.metrics)
        _ = try await indexer.update { _ in }
        try env.store.deleteIndex()
        _ = try await indexer.update { _ in }
        let repeated = try env.read().events.filter { $0["event"] as? String == "reindexed_file" }
        #expect(repeated.count == 1)
        #expect(repeated.first?["phase"] as? String == "text")
    }

    @Test func switchedOffAgainWritesNoMoreLines() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        env.metrics.setEnabled(true)
        env.metrics.log("eins")
        env.metrics.setEnabled(false)
        env.metrics.log("zwei")
        let names = try env.read().events.compactMap { $0["event"] as? String }
        #expect(names == ["logging_on", "eins"])
    }

    /// 1.3.10: „Mess-Protokolle löschen“ removes the protocol files only; logging goes on in a new file.
    @Test func deleteLogsRemovesProtocolsAndKeepsLogging() throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        env.metrics.setEnabled(true)
        env.metrics.log("scan", ["files": 1])
        env.metrics.flush()
        try FileManager.default.createDirectory(at: env.logs, withIntermediateDirectories: true)
        try Data("bleibt".utf8).write(to: env.logs.appendingPathComponent("anderes.log"))
        #expect(env.metrics.logFiles().count == 1)
        env.metrics.deleteLogs()
        #expect(env.metrics.logFiles().isEmpty)
        #expect(FileManager.default.fileExists(atPath: env.logs.appendingPathComponent("anderes.log").path))
        env.metrics.log("scan", ["files": 2])
        env.metrics.flush()
        let files = env.metrics.logFiles()
        #expect(files.count == 1)
        let text = try String(contentsOf: try #require(files.first), encoding: .utf8)
        #expect(text.contains("\"files\":2") && !text.contains("\"files\":1"))
    }
}
