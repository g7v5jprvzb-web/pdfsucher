import Foundation
import IndexKit
import Testing
import TestSupport

/// 1.4.3: the measurement log on by default, kept 7 days, exported as a ZIP; blocked main thread logged and sampled.
@Suite("Measurement log 1.4.3", .serialized)
struct MeasurementLog143Tests {
    private func events(_ logs: URL) throws -> [[String: Any]] {
        let files = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? []
        return try files.filter { $0.pathExtension == "jsonl" }.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
            .split(separator: "\n").compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    @Test func onUnlessSwitchedOff() throws {
        let name = "MeasurementLog143Tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(IndexMetrics.isEnabledSetting(defaults))
        defaults.set(false, forKey: IndexMetrics.defaultsKey)
        #expect(!IndexMetrics.isEnabledSetting(defaults))
        defaults.set(true, forKey: IndexMetrics.defaultsKey)
        #expect(IndexMetrics.isEnabledSetting(defaults))
    }

    @Test func deletesFilesOlderThanSevenDays() throws {
        let logs = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: logs) }
        let names = ["index-metrics-2026-11-12.jsonl", "index-metrics-2026-11-13.jsonl", "index-metrics-2026-11-20.jsonl",
                     "hang-2026-11-12_235959.txt", "hang-2026-11-13_000001.txt", "ui-rows-2026-11-01.jsonl", "other-2026-01-01.jsonl"]
        for name in names { FileManager.default.createFile(atPath: logs.appendingPathComponent(name).path, contents: Data()) }
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 12)))
        for prefix in ["index-metrics", "ui-rows", "hang"] {
            let metrics = IndexMetrics(directory: logs, prefix: prefix)
            metrics.deleteLogs(olderThan: 7, now: now)
            metrics.flush()
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: logs.path).sorted()
        #expect(left == ["hang-2026-11-13_000001.txt", "index-metrics-2026-11-13.jsonl", "index-metrics-2026-11-20.jsonl",
                         "other-2026-01-01.jsonl"])
    }

    @Test func exportPacksEveryProtocol() throws {
        let base = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let logs = base.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let metrics = IndexMetrics(directory: logs), rows = IndexMetrics(directory: logs, prefix: "ui-rows")
        let hangs = IndexMetrics(directory: logs, prefix: "hang")
        metrics.setEnabled(true)
        metrics.log("test", ["x": 1])          // still buffered: export writes it first
        FileManager.default.createFile(atPath: logs.appendingPathComponent("hang-2026-11-20_120000.txt").path, contents: Data("stack".utf8))
        FileManager.default.createFile(atPath: logs.appendingPathComponent("fremd.txt").path, contents: Data())
        let zip = base.appendingPathComponent("PDFSucher-Protokolle-2026-11-20.zip")
        try IndexMetrics.export([metrics, rows, hangs], to: zip)
        let out = base.appendingPathComponent("out", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, out.path]
        try ditto.run()
        ditto.waitUntilExit()
        let folder = out.appendingPathComponent("PDFSucher-Protokolle-2026-11-20", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files.count == 2)
        #expect(files.first == "hang-2026-11-20_120000.txt")
        #expect(files.last?.hasPrefix("index-metrics-") == true)
        let text = try String(contentsOf: folder.appendingPathComponent(try #require(files.last)), encoding: .utf8)
        #expect(text.contains("\"event\":\"test\""))
    }

    /// A main queue blocked for 1.5 s: one `main_hang` with its phase, the last launch phase and a sample file that
    /// holds the main thread's stack.
    @Test func blockedMainQueueIsLoggedAndSampled() async throws {
        let logs = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: logs) }
        let metrics = IndexMetrics(directory: logs)
        metrics.setEnabled(true)
        let watch = MainHangWatch(metrics: metrics, threshold: .milliseconds(250), interval: .milliseconds(20),
                                  sampleAfter: .milliseconds(300), sampleSeconds: 1)
        watch.setPhase("ocr")
        watch.launchPhase("restore_begin")
        watch.start()
        defer { watch.stop() }
        try await Task.sleep(for: .milliseconds(200))
        await MainActor.run { Thread.sleep(forTimeInterval: 1.5) }
        try await Task.sleep(for: .milliseconds(2500))        // the sample (1 s) is written
        metrics.flush()
        let all = try events(logs)
        let hangs = all.filter { $0["event"] as? String == "main_hang" }
        #expect(hangs.count == 1)
        let hang = try #require(hangs.first)
        #expect((hang["ms"] as? Double ?? 0) >= 1400)
        #expect(hang["phase"] as? String == "ocr")
        #expect(hang["last_launch_phase"] as? String == "restore_begin")
        #expect(all.contains { $0["event"] as? String == "launch_phase" && $0["name"] as? String == "restore_begin" && $0["ms"] is Double })
        let sample = try #require(hang["sample"] as? String)
        #expect(sample.hasPrefix("hang-") && sample.hasSuffix(".txt"))
        let text = try String(contentsOf: logs.appendingPathComponent(sample), encoding: .utf8)
        #expect(text.contains("Thread_") || text.contains("Thread "))
        #expect(text.contains("blockedMainQueueIsLoggedAndSampled") || text.contains("sleepForTimeInterval") || text.contains("nanosleep"))
    }

    @Test func shortDelaysWriteNothing() async throws {
        let logs = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: logs) }
        let metrics = IndexMetrics(directory: logs)
        metrics.setEnabled(true)
        let watch = MainHangWatch(metrics: metrics, threshold: .milliseconds(250), interval: .milliseconds(20))
        watch.start()
        defer { watch.stop() }
        await MainActor.run { Thread.sleep(forTimeInterval: 0.05) }
        try await Task.sleep(for: .milliseconds(300))
        metrics.flush()
        #expect(try events(logs).allSatisfy { $0["event"] as? String != "main_hang" })
    }
}
