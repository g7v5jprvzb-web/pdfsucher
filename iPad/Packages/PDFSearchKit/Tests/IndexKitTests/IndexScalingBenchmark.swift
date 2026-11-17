import Foundation
@testable import IndexKit
import Synchronization
import Testing
import TestSupport

/// Opt-in measurements on real PDFs (index-speed, 2026-11-16). Reads only; prints numbers, never names or text.
///
///     PDFSUCHER_PDF_SCALING_BENCH=1 [PDFSUCHER_BENCH_ROOT=~/Documents] [PDFSUCHER_BENCH_COUNT=400] \
///     PDFSUCHER_BENCH_OUT=<dir> swift test -c release --filter IndexScalingBenchmark
///
/// Writes to `<out>`: `sample.txt` (absolute paths of the sample, for `scripts/pdfkit-process-bench.swift`),
/// `logs/` (measurement log of the indexer run) and `results.json`.
@Suite("Index scaling benchmark", .serialized)
struct IndexScalingBenchmark {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["PDFSUCHER_PDF_SCALING_BENCH"] == "1"

    struct Sample {
        let root: URL, out: URL
        let files: [URL]
    }

    /// The same files every time: every PDF below the root, sorted by path, shuffled with seed 42.
    static func sample() throws -> Sample {
        let root = URL(fileURLWithPath: env["PDFSUCHER_BENCH_ROOT"] ?? NSHomeDirectory() + "/Documents", isDirectory: true)
        let out = URL(fileURLWithPath: env["PDFSUCHER_BENCH_OUT"] ?? NSTemporaryDirectory() + "pdfsucher-bench", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let count = Int(env["PDFSUCHER_BENCH_COUNT"] ?? "") ?? 400
        var all = try FolderScanner().scan(root: root).filter { $0.kind == .pdf }.sorted { $0.relativePath < $1.relativePath }
        var rng = SeededGenerator(seed: 42)
        all.shuffle(using: &rng)
        let files = all.prefix(count).map(\.url)
        try files.map(\.path).joined(separator: "\n").write(to: out.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
        return Sample(root: root, out: out, files: Array(files))
    }

    struct Run: Codable {
        var order = "sample", tasks = 0, files = 0, pages = 0, failed = 0
        var wallS = 0.0, sumS = 0.0, maxFileS = 0.0, pagesPerS = 0.0, speedup = 0.0, parallelism = 0.0
    }

    static func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

    static func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

    /// Extracts every file with `PDFKitTextSource`, at most `tasks` at once (like the indexer's task group).
    static func extract(_ files: [URL], tasks: Int) async -> (Run, [[PageText]]) {
        let source = PDFKitTextSource()
        let start = ContinuousClock.now
        var run = Run(tasks: tasks, files: files.count)
        var texts = [[PageText]](repeating: [], count: files.count)
        await withTaskGroup(of: (Int, [PageText]?, Double).self) { group in
            var next = 0
            func add() {
                guard next < files.count else { return }
                let i = next
                next += 1
                group.addTask {
                    let t = ContinuousClock.now
                    let pages = try? source.pages(of: files[i])
                    return (i, pages, seconds(.now - t))
                }
            }
            for _ in 0..<tasks { add() }
            while let (i, pages, s) = await group.next() {
                run.sumS += s
                run.maxFileS = max(run.maxFileS, s)
                if let pages { run.pages += pages.count; texts[i] = pages } else { run.failed += 1 }
                add()
            }
        }
        run.wallS = seconds(.now - start)
        run.pagesPerS = Double(run.pages) / run.wallS
        run.parallelism = run.sumS / run.wallS
        return (run, texts)
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(60)))
    func scalingOfPDFReading() async throws {
        let sample = try Self.sample()
        _ = await Self.extract(sample.files, tasks: 15)           // warm the file cache: every run reads from memory
        var runs: [Run] = []
        let bySize = sample.files.sorted { Self.size($0) > Self.size($1) }
        for (order, files) in [("sample", sample.files), ("largest_first", bySize)] {
            for tasks in [1, 4, 8, 15] where order == "sample" || tasks > 1 {
                var (run, _) = await Self.extract(files, tasks: tasks)
                run.order = order
                run.speedup = (runs.first?.wallS ?? run.wallS) / run.wallS
                runs.append(run)
                print(String(format: "SCALING order=%@ tasks=%2d files=%d pages=%d failed=%d wall=%.2fs sum=%.2fs max_file=%.2fs pages/s=%.0f speedup=%.2f parallelism=%.2f",
                             order, run.tasks, run.files, run.pages, run.failed, run.wallS, run.sumS, run.maxFileS, run.pagesPerS,
                             run.speedup, run.parallelism))
            }
        }
        let data = try JSONEncoder().encode(runs)
        try data.write(to: sample.out.appendingPathComponent("scaling.json"))
    }

    /// The sample through the real indexer into a temporary index (symbolic links to the files), with the measurement log.
    @Test(.enabled(if: enabled), .timeLimit(.minutes(60)))
    func sampleThroughTheIndexer() async throws {
        let sample = try Self.sample()
        let work = sample.out.appendingPathComponent("indexer-\(UUID().uuidString)", isDirectory: true)
        let root = work.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for (i, url) in sample.files.enumerated() {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(String(format: "f%05d.pdf", i)), withDestinationURL: url)
        }
        _ = await Self.extract(sample.files, tasks: 15)           // same warm cache as the scaling test
        let logs = sample.out.appendingPathComponent("logs", isDirectory: true)
        let metrics = IndexMetrics(directory: logs)
        metrics.setEnabled(true)
        let store = try IndexStore(fileURL: work.appendingPathComponent("index.sqlite"), root: root)
        let start = ContinuousClock.now
        let report = try await IndexMetrics.$run.withValue(metrics.nextRun()) {
            try await Indexer(root: root, store: store, metrics: metrics).update { _ in }
        }
        let wall = Self.seconds(.now - start)
        metrics.setEnabled(false)
        print(String(format: "INDEXER files=%d failed=%d wall=%.2fs", report.added, report.failed.count, wall))
        #expect(report.added == sample.files.count)
    }

    /// Cost of each FTS5 index: the sample's pages written in batches of 50 into four schemas — both FTS indexes (as in the
    /// app), word index only, trigram index only, none. Also prints the connection's PRAGMAs.
    @Test(.enabled(if: enabled), .timeLimit(.minutes(60)))
    func costOfEachFTSIndex() async throws {
        let sample = try Self.sample()
        let (_, texts) = await Self.extract(sample.files, tasks: 15)
        let scanned = sample.files.enumerated().map { i, url in
            ScannedFile(relativePath: String(format: "f%05d.pdf", i), url: url, fileSize: 1, modifiedAt: Date(timeIntervalSince1970: 0))
        }
        let work = sample.out.appendingPathComponent("fts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let insertWords = "INSERT INTO pages_words(rowid, text) VALUES (new.id, new.text);"
        let insertTrigram = "INSERT INTO pages_trigram(rowid, text) VALUES (new.id, new.text);"
        let variants: [(String, String?)] = [("both", nil), ("words_only", insertWords), ("trigram_only", insertTrigram), ("none", "")]
        var results: [String: Double] = [:]
        for (name, trigger) in variants {
            let file = work.appendingPathComponent("\(name).sqlite")
            let store = try IndexStore(fileURL: file, root: work)
            let db = try SQLiteConnection(path: file.path)
            if let trigger {
                try db.execute("DROP TRIGGER page_text_ai; CREATE TRIGGER page_text_ai AFTER INSERT ON page_text BEGIN SELECT 1; \(trigger) END;")
            } else {
                // Defaults of a new connection = those of the store's (it sets only journal_mode and foreign_keys).
                for pragma in ["journal_mode", "synchronous", "cache_size", "page_size", "wal_autocheckpoint", "temp_store", "mmap_size"] {
                    print("PRAGMA \(pragma)=\(try db.query("PRAGMA \(pragma)", []).first?.values.first.map { "\($0)" } ?? "?")")
                }
            }
            var timing = IndexStore.UpsertTiming()
            let start = ContinuousClock.now
            for batch in stride(from: 0, to: scanned.count, by: 50) {
                let items = (batch..<min(batch + 50, scanned.count)).map { (scanned[$0], texts[$0], DocumentStatus.ok, false) }
                let t = try store.upsertBatch(items)
                timing.pagesMs += t.pagesMs
                timing.commitMs += t.commitMs
            }
            results[name] = Self.seconds(.now - start)
            print(String(format: "FTS variant=%@ total=%.2fs pages+fts=%.2fs commit=%.2fs size=%.1fMB", name, results[name]!,
                         timing.pagesMs / 1000, timing.commitMs / 1000,
                         Double((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0) / 1e6))
        }
        let pages = texts.reduce(0) { $0 + $1.count }, chars = texts.reduce(0) { $0 + $1.reduce(0) { $0 + $1.text.utf8.count } }
        print(String(format: "FTS pages=%d text=%.1fMB words_index=%.2fs trigram_index=%.2fs base=%.2fs", pages, Double(chars) / 1e6,
                     results["both"]! - results["trigram_only"]!, results["both"]! - results["words_only"]!, results["none"]!))
    }
}
