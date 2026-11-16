import Foundation
import IndexKit
import SearchKit
import Testing
import TestSupport

/// Opt-in before/after measurement of 1.3.12 on real PDFs (reads only, temporary index, prints numbers only):
///
///     PDFSUCHER_PDF_SCALING_BENCH=1 [PDFSUCHER_BENCH_ROOT=~/Documents] [PDFSUCHER_BENCH_COUNT=100000] \
///     PDFSUCHER_BENCH_OUT=<dir> swift test -c release -Xswiftc -enable-testing --filter WordPartsBenchmark
///
/// Phase 1, then an infix search with every page still waiting for the trigram index, again at half, the Wortteil-Index,
/// and the search once it is complete.
@Suite("Wortteil-Index benchmark")
struct WordPartsBenchmark {
    static let env = ProcessInfo.processInfo.environment

    static func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

    @Test(.enabled(if: env["PDFSUCHER_PDF_SCALING_BENCH"] == "1"), .timeLimit(.minutes(60)))
    func phaseOneThenWordParts() async throws {
        let source = URL(fileURLWithPath: Self.env["PDFSUCHER_BENCH_ROOT"] ?? NSHomeDirectory() + "/Documents", isDirectory: true)
        let out = URL(fileURLWithPath: Self.env["PDFSUCHER_BENCH_OUT"] ?? NSTemporaryDirectory() + "pdfsucher-bench", isDirectory: true)
        let count = Int(Self.env["PDFSUCHER_BENCH_COUNT"] ?? "") ?? 100_000
        var all = try FolderScanner().scan(root: source).filter { $0.kind == .pdf }.sorted { $0.relativePath < $1.relativePath }
        var rng = SeededGenerator(seed: 42)
        all.shuffle(using: &rng)
        let files = all.prefix(count).map(\.url)
        let work = out.appendingPathComponent("wordparts-\(UUID().uuidString)", isDirectory: true)
        let root = work.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for (i, url) in files.enumerated() {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(String(format: "f%05d.pdf", i)), withDestinationURL: url)
        }
        for url in files { _ = try? Data(contentsOf: url) }                 // warm the file cache
        let metrics = IndexMetrics(directory: out.appendingPathComponent("logs", isDirectory: true))
        metrics.setEnabled(true)
        let store = try IndexStore(fileURL: work.appendingPathComponent("index.sqlite"), root: root)
        let indexer = Indexer(root: root, store: store, metrics: metrics)
        let service = SearchService(index: store, root: root)

        func search(_ text: String) throws -> (s: Double, docs: Int) {
            let start = ContinuousClock.now
            let hits = try service.search(QueryParser.parse(text, partialWords: false), sort: .fileName)
            return (Self.seconds(.now - start), hits.count)
        }

        let start = ContinuousClock.now
        _ = try await IndexMetrics.$run.withValue(metrics.nextRun()) { try await indexer.update { _ in } }
        let phase1 = Self.seconds(.now - start)
        let pending = try store.trigramProgress().pending
        let word = try search("vertrag*")
        let infix = ["*vertrag*", "*rechnung*", "*steuer*"]
        let during = try infix.map(search)
        // Half of it, then the rest through the real step.
        let wpStart = ContinuousClock.now
        while try store.trigramProgress().pending > pending / 2 { try store.fillTrigramIndex(maxPages: 1_000) }
        let half = try infix.map(search)
        let halfDone = ContinuousClock.now
        _ = try await IndexMetrics.$run.withValue(metrics.nextRun()) { try await indexer.buildWordParts { _ in } }
        let wordParts = Self.seconds(halfDone - wpStart) + Self.seconds(.now - halfDone)
        let after = try infix.map(search)
        metrics.setEnabled(false)
        #expect(during.map(\.docs) == after.map(\.docs), "same hits while the index is built")
        #expect(half.map(\.docs) == after.map(\.docs))
        func list(_ r: [(s: Double, docs: Int)]) -> String { r.map { String(format: "%.2fs/%d", $0.s, $0.docs) }.joined(separator: " ") }
        print(String(format: "WORDPARTS files=%d phase1=%.2fs pending_pages=%d word_search=%.2fs wordparts=%.2fs total=%.2fs",
                     files.count, phase1, pending, word.s, wordParts, phase1 + wordParts))
        print("WORDPARTS infix during=\(list(during)) half=\(list(half)) after=\(list(after))")
    }
}
