import Testing
import Foundation
import IndexKit
import TestSupport

private func seconds(_ body: () async throws -> Void) async rethrows -> Double {
    let clock = ContinuousClock()
    let d = try await clock.measure { try await body() }
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

@Suite("Performance")
struct PerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_PERF"] == "1"),
          .timeLimit(.minutes(30)))
    func perfThousandDocs() async throws {
        let base = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("pdfs", isDirectory: true)
        var rng = SeededGenerator(seed: 42)
        let words = PerfCorpus.wordList(using: &rng)

        let generation = try await seconds {
            for d in 0..<1_000 {
                let dir = root.appendingPathComponent(String(format: "ordner%02d", d / 50), isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let pages = (0..<20).map { _ in PerfCorpus.page(words, using: &rng) }
                try PDFFixtures.makePDF(at: dir.appendingPathComponent(String(format: "dok%04d.pdf", d)), pages: pages)
            }
            let big = (0..<2_000).map { _ in PerfCorpus.page(words, using: &rng) }
            try PDFFixtures.makePDF(at: root.appendingPathComponent("gross_2000_seiten.pdf"), pages: big)
        }

        let storeURL = base.appendingPathComponent("index.sqlite")
        let store = try IndexStore(fileURL: storeURL, root: root)
        let indexer = Indexer(root: root, store: store)

        var firstReport = IndexReport()
        let firstIndex = try await seconds { firstReport = try await indexer.update { _ in } }
        #expect(firstReport.added == 1_001)
        #expect(firstReport.failed.isEmpty)

        var secondReport = IndexReport()
        let reindex = try await seconds { secondReport = try await indexer.update { _ in } }
        #expect(secondReport == IndexReport(unchanged: 1_001))

        // 20 queries: 10 whole words, 5 prefixes (words index), 5 infixes (trigram index).
        var queries: [(String, FTSTable)] = []
        for w in words.prefix(10) { queries.append(("\"\(w.lowercased())\"", .words)) }
        for w in words.dropFirst(10).prefix(5) { queries.append(("\"\(w.lowercased().prefix(4))\"*", .words)) }
        for w in words.dropFirst(15).prefix(5) {
            let s = w.lowercased()
            let mid = s.index(s.startIndex, offsetBy: 1)
            queries.append(("\"\(s[mid...].prefix(4))\"", .trigram))
        }
        var times: [Double] = []
        var rows: [Int] = []
        for (q, table) in queries {
            var n = 0
            times.append(try await seconds { n = try store.match(q, in: table).count })
            rows.append(n)
        }
        let sorted = times.sorted()
        let median = (sorted[9] + sorted[10]) / 2
        let fileSize = (try FileManager.default.attributesOfItem(atPath: storeURL.path)[.size] as? Int64) ?? 0

        print("""

        | Messung | Wert |
        |---|---|
        | Korpus erzeugen (1.001 PDFs, 22.000 Seiten) | \(String(format: "%.1f s", generation)) |
        | Erst-Index | \(String(format: "%.1f s", firstIndex)) |
        | Neu-Index ohne Änderungen | \(String(format: "%.2f s", reindex)) |
        | Abfrage Median (20 Abfragen) | \(String(format: "%.1f ms", median * 1000)) |
        | Abfrage Max | \(String(format: "%.1f ms", (sorted.last ?? 0) * 1000)) |
        | Treffer-Seiten je Abfrage (min/Median/max) | \(rows.min() ?? 0) / \((rows.sorted()[9] + rows.sorted()[10]) / 2) / \(rows.max() ?? 0) |
        | Index-Datei | \(String(format: "%.0f MB", Double(fileSize) / 1_048_576)) |
        | Kerne | \(ProcessInfo.processInfo.activeProcessorCount) |

        """)
        for (i, (q, table)) in queries.enumerated() {
            print(String(format: "  %-22@ %-8@ %7.1f ms  %6d Seiten", q as NSString, "\(table)" as NSString, times[i] * 1000, rows[i]))
        }

        #expect(reindex < 5, "Neu-Index ohne Änderungen: \(reindex) s")
        #expect(median < 0.2, "Median-Abfrage: \(median * 1000) ms")
    }

    @Test func perfCorpusPagesFitOnePage() throws {
        // Guards the generator: a page must stay well below the ~49 lines a fixture page holds.
        var rng = SeededGenerator(seed: 42)
        let words = PerfCorpus.wordList(using: &rng)
        let dir = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let longest = words.sorted { $0.count > $1.count }
        let worst = stride(from: 0, to: PerfCorpus.wordsPerPage, by: 8)
            .map { _ in longest.prefix(8).joined(separator: " ") }.joined(separator: "\n")
        try PDFFixtures.makePDF(at: dir.appendingPathComponent("worst.pdf"), pages: [worst])
        #expect(words.count == 2_000)
        #expect(Set(words.map { $0.lowercased() }).count == 2_000)
    }
}
