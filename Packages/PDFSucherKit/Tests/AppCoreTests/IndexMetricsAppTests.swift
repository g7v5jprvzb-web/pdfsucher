import Foundation
import IndexKit
import Testing
import TestSupport
@testable import AppCore

/// 1.3.9: each phase-1 run in the measurement log names why it ran (`trigger`), and sources coming and going are logged.
@MainActor @Suite("Measurement log in the app", .timeLimit(.minutes(1)))
struct IndexMetricsAppTests {
    @Test func runsCarryTheirTrigger() async throws {
        let base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let akten = base.appendingPathComponent("Akten", isDirectory: true)
        try FileManager.default.createDirectory(at: akten, withIntermediateDirectories: true)
        let logs = base.appendingPathComponent("Logs", isDirectory: true)
        let metrics = IndexMetrics(directory: logs)
        metrics.setEnabled(true)
        let watcher = FakeWatcher()
        let index = FakeIndex()
        let m = AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "Metrics-\(UUID().uuidString)")!,
                         environment: FakeEnvironment(), debounce: .zero, openIndex: { _ in index })
        m.metrics = metrics
        m.diskChangeCooldown = .zero
        m.folderWatcher = watcher

        await m.add([akten])
        await m.waitUntilIdle()
        watcher.fire([akten.path])
        await m.waitUntilIdle()
        m.removeSource(akten)

        metrics.flush()
        let raw = try String(contentsOf: try #require(FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil).first),
                             encoding: .utf8)
        #expect(!raw.contains("Akten"))
        let events = raw.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        func named(_ name: String) -> [[String: Any]] { events.filter { $0["event"] as? String == name } }
        let source = IndexMetrics.hash(akten)
        let starts = named("run_start").filter { $0["phase"] as? String == "text" }
        #expect(starts.map { $0["trigger"] as? String } == ["added", "disk_change"])
        #expect(starts.allSatisfy { $0["source"] as? String == source })
        #expect(Set(named("run_end").compactMap { $0["run"] as? Int }) == Set(named("run_start").compactMap { $0["run"] as? Int }))
        #expect(named("source_added").first?["trigger"] as? String == "added")
        #expect(named("source_removed").first?["reason"] as? String == "user")
    }

    /// 1.4.3: one `search` per search run (counts, no query text) and `source_storage` per added source.
    @Test func searchesAndStorageAreLogged() async throws {
        let base = try PDFFixtures.tempDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let akten = base.appendingPathComponent("Akten", isDirectory: true)
        try FileManager.default.createDirectory(at: akten, withIntermediateDirectories: true)
        let logs = base.appendingPathComponent("Logs", isDirectory: true)
        let metrics = IndexMetrics(directory: logs)
        metrics.setEnabled(true)
        let m = AppModel(settings: makeSettings(), defaults: UserDefaults(suiteName: "Metrics-\(UUID().uuidString)")!,
                         environment: FakeEnvironment(), debounce: .zero, openIndex: { _ in FakeIndex() })
        m.metrics = metrics
        m.hangWatch = MainHangWatch(metrics: metrics)
        await m.add([akten])
        await m.waitUntilIdle()
        m.queryText = "geheimwort zwei"
        var events: [[String: Any]] = []
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(10))
            metrics.flush()
            let files = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? []
            let raw = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
            #expect(!raw.contains("geheimwort"))
            events = raw.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            if events.contains(where: { $0["event"] as? String == "search" }), events.contains(where: { $0["event"] as? String == "source_storage" }) { break }
        }
        let search = try #require(events.first { $0["event"] as? String == "search" && $0["cancelled"] as? Bool == false })
        #expect(search["terms"] as? Int == 2)
        #expect(search["sources"] as? Int == 1)
        #expect(search["hits"] is Int)
        #expect(search["indexing"] is String)
        for key in ["total_ms", "first_rows_ms", "debounce_ms"] { #expect(search[key] as? NSNumber != nil, "\(key)") }
        #expect(events.contains { $0["event"] as? String == "launch_phase" && $0["name"] as? String == "first_search_done" })
        let storage = try #require(events.first { $0["event"] as? String == "source_storage" })
        #expect(storage["source"] as? String == IndexMetrics.hash(akten))
        #expect(storage["volume_local"] as? Bool == true)
        #expect(storage["ubiquitous"] as? Bool == false)
        #expect(storage["volume_type"] as? String == "apfs")
    }
}
