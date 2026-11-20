import Foundation
@testable import IndexKit
import Testing

/// Opt-in (pdf-dubletten): phase 1 over every PDF of a real folder into a temporary index, twice (the first warms the file
/// cache), with the measurement log; prints numbers only, never names or text.
///
///     PDFSUCHER_PDF_SCALING_BENCH=1 [PDFSUCHER_BENCH_ROOT=~/Documents] PDFSUCHER_BENCH_OUT=<dir> \
///     swift test -c release --filter DuplicateBenchmark
///
/// The measured run's log is `<out>/logs-dedup/` (evaluate with `scripts/index-metrics-report.py`).
@Suite("Duplicate PDF benchmark", .serialized)
struct DuplicateBenchmark {
    static let env = ProcessInfo.processInfo.environment

    @Test(.enabled(if: env["PDFSUCHER_PDF_SCALING_BENCH"] == "1"), .timeLimit(.minutes(60)))
    func phaseOneOverTheRealFolder() async throws {
        let root = URL(fileURLWithPath: Self.env["PDFSUCHER_BENCH_ROOT"] ?? NSHomeDirectory() + "/Documents", isDirectory: true)
        let out = URL(fileURLWithPath: Self.env["PDFSUCHER_BENCH_OUT"] ?? NSTemporaryDirectory() + "pdfsucher-bench", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for pass in ["warm", "dedup"] {
            let work = out.appendingPathComponent("index-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let metrics = IndexMetrics(directory: out.appendingPathComponent("logs-\(pass)", isDirectory: true))
            metrics.setEnabled(true)
            let store = try IndexStore(fileURL: work.appendingPathComponent("index.sqlite"), root: root)
            let start = ContinuousClock.now
            let report = try await Indexer(root: root, store: store, metrics: metrics).update { _ in }
            let wall = ContinuousClock.now - start
            metrics.setEnabled(false)
            let pages = try store.allPages().count
            print("DEDUP pass=\(pass) files=\(report.added) failed=\(report.failed.count) noText=\(report.noText.count) pages=\(pages) wall=\(wall)")
            for word in ["vertrag", "rechnung", "steuer", "miete", "und", "versicherung"] {
                let hits = try store.match(word, in: .words)
                print("DEDUP pass=\(pass) word=\(word) pages=\(hits.count) documents=\(Set(hits.map(\.docId)).count)")
            }
        }
    }
}
