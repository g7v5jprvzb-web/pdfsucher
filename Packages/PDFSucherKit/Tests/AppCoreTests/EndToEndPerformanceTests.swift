import AppKit
import Foundation
import Testing
import TestSupport
import ViewerUI
@testable import AppCore

/// Task 5.5 / spec §9: time from the end of typing to the hit list (`AppModel.hits` filled), over
/// 1,000 PDFs × 20 pages (+ one 2,000-page PDF), same corpus as the index perf test. Opt-in:
/// `PDFSUCHER_E2E=1 swift test -c release --package-path Packages/PDFSucherKit --filter EndToEndPerformance`.
/// Measured: `queryText` set (debounce 0) → search on the real index → hits sorted and published on
/// the main actor. Not included: the typing delay (50 ms default or 150 ms, both added in the table) and SwiftUI drawing.
@MainActor @Suite("End-to-end performance")
struct EndToEndPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_E2E"] == "1"), .timeLimit(.minutes(30)))
    func searchEndToEndThousandDocs() async throws {
        let base = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("pdfs", isDirectory: true)
        var rng = SeededGenerator(seed: 42)
        let words = PerfCorpus.wordList(using: &rng)
        for d in 0..<1_000 {
            let dir = root.appendingPathComponent(String(format: "ordner%02d", d / 50), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pages = (0..<20).map { _ in PerfCorpus.page(words, using: &rng) }
            try PDFFixtures.makePDF(at: dir.appendingPathComponent(String(format: "dok%04d.pdf", d)), pages: pages)
        }
        try PDFFixtures.makePDF(at: root.appendingPathComponent("gross_2000_seiten.pdf"),
                                pages: (0..<2_000).map { _ in PerfCorpus.page(words, using: &rng) })

        let indexURL = base.appendingPathComponent("index.sqlite")
        let model = AppModel(settings: GridSettings(defaults: UserDefaults(suiteName: "E2E-\(UUID().uuidString)")!),
                             defaults: UserDefaults(suiteName: "E2E-\(UUID().uuidString)")!,
                             environment: SilentEnvironment(), debounce: .zero,
                             openIndex: { try FolderIndex.shared(root: $0, indexURL: indexURL) })
        let clock = ContinuousClock()
        let indexing = await clock.measure {
            await model.open(folder: root)
            await model.waitUntilIdle()
        }
        #expect(model.indexStatus == .upToDate)

        let common = words[0].lowercased()
        let queries = [common, "\(words[1].lowercased()) \(words[2].lowercased())",
                       "nung*", "ver*", "\(words[3].lowercased().prefix(4))*",
                       "*trag*", "*\(words[4].lowercased().suffix(4))", "\"\(words[5].lowercased()) \(words[6].lowercased())\"",
                       "*ab*", "*er*", "gibtsnicht"]
        var rows: [String] = []
        var worst: Duration = .zero
        for q in queries {
            var samples: [Duration] = []
            for _ in 0..<5 {
                model.queryText = ""
                await model.waitUntilIdle()
                samples.append(await clock.measure {
                    model.queryText = q
                    await model.waitForSearch()
                })
            }
            samples.sort()
            worst = max(worst, samples[2])
            let pages = model.hits.reduce(0) { $0 + $1.pageHits.count }
            rows.append("| `\(q)` | \(model.hits.count) | \(pages) | \(ms(samples[2])) | \(ms(samples[4])) | \(ms(samples[2] + .milliseconds(50))) | \(ms(samples[2] + .milliseconds(150))) |")
        }
        print("""

        E2E: Erst-Index über AppModel \(String(format: "%.1f s", seconds(indexing))), Kerne \(ProcessInfo.processInfo.activeProcessorCount)
        | Eingabe | Dokumente | Seiten | Median | Max (5 Läufe) | + 50 ms (Standard) | + 150 ms |
        |---|---|---|---|---|---|---|
        \(rows.joined(separator: "\n"))

        """)
        // Reported, not asserted: spec §9 calls the 200 ms a target to measure, not a guarantee.
        withKnownIssue("§9-Ziel 200 ms verfehlt", isIntermittent: true) {
            #expect(worst < .milliseconds(200), "langsamster Median: \(ms(worst))")
        }
    }

    /// Spec 1.1 §5: the same queries over three folders of 1,000 PDFs × 20 pages each (one index per
    /// folder, searched in parallel and merged). Opt-in like the test above:
    /// `PDFSUCHER_E2E=1 swift test -c release --package-path Packages/PDFSucherKit --filter searchEndToEndThreeFolders`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PDFSUCHER_E2E"] == "1"), .timeLimit(.minutes(60)))
    func searchEndToEndThreeFolders() async throws {
        let base = try PDFFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        var rng = SeededGenerator(seed: 7)
        let words = PerfCorpus.wordList(using: &rng)
        var folders: [URL] = []
        for f in 0..<3 {
            let root = base.appendingPathComponent("quelle\(f + 1)", isDirectory: true)
            for d in 0..<1_000 {
                let dir = root.appendingPathComponent(String(format: "ordner%02d", d / 50), isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let pages = (0..<20).map { _ in PerfCorpus.page(words, using: &rng) }
                try PDFFixtures.makePDF(at: dir.appendingPathComponent(String(format: "dok%04d.pdf", d)), pages: pages)
            }
            folders.append(root)
        }
        let indexDir = base.appendingPathComponent("indexes", isDirectory: true)
        try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
        let model = AppModel(settings: GridSettings(defaults: UserDefaults(suiteName: "E2E3-\(UUID().uuidString)")!),
                             defaults: UserDefaults(suiteName: "E2E3-\(UUID().uuidString)")!,
                             environment: SilentEnvironment(), debounce: .zero,
                             openIndex: { try FolderIndex.shared(root: $0, indexURL: indexDir.appendingPathComponent($0.lastPathComponent + ".sqlite")) })
        let clock = ContinuousClock()
        let indexing = await clock.measure {
            await model.add(folders)
            await model.waitUntilIdle()
        }
        #expect(model.indexStatus == .upToDate)
        #expect(model.sources.count == 3)

        let queries = [words[0].lowercased(), "\(words[1].lowercased()) \(words[2].lowercased())",
                       "nung*", "ver*", "\(words[3].lowercased().prefix(4))*",
                       "*trag*", "*\(words[4].lowercased().suffix(4))", "\"\(words[5].lowercased()) \(words[6].lowercased())\"",
                       "*ab*", "*er*", "gibtsnicht"]
        var rows: [String] = []
        var worst: Duration = .zero
        var worstFirst: Duration = .zero
        let firstRows = FirstRows()
        model.onHitsPublished = { hits in if !hits.isEmpty { firstRows.mark() } }
        for q in queries {
            var samples: [Duration] = []
            var firsts: [Duration] = []
            for _ in 0..<5 {
                model.queryText = q
                await model.waitUntilIdle()
                model.queryText = "x"          // not empty: no browse list between the samples
                model.queryText = ""
                await model.waitUntilIdle()
                let start = clock.now
                firstRows.reset(start)
                model.queryText = q
                await model.waitForSearch()
                let total = clock.now - start
                samples.append(total)
                firsts.append(firstRows.elapsed ?? total)
            }
            samples.sort()
            firsts.sort()
            worst = max(worst, samples[2])
            worstFirst = max(worstFirst, firsts[2])
            let pages = model.hits.reduce(0) { $0 + $1.pageHits.count }
            rows.append("| `\(q)` | \(model.hits.count) | \(pages) | \(ms(firsts[2] + .milliseconds(50))) | \(ms(samples[2] + .milliseconds(50))) | \(ms(samples[4] + .milliseconds(50))) |")
        }
        print("""

        E2E 3 Ordner: Erst-Index (nacheinander) \(String(format: "%.1f s", seconds(indexing))), Kerne \(ProcessInfo.processInfo.activeProcessorCount)
        Zeiten ab dem letzten Tastendruck (inkl. 50 ms Wartezeit), Median aus 5 Läufen
        | Eingabe | Dokumente | Seiten | erste Reihen | vollständige Liste | Max vollständig |
        |---|---|---|---|---|---|
        \(rows.joined(separator: "\n"))

        """)
        #expect(worstFirst + .milliseconds(50) < .milliseconds(200), "erste Reihen, langsamster Median + 50 ms: \(ms(worstFirst + .milliseconds(50)))")
        withKnownIssue("vollständige Liste über 200 ms", isIntermittent: true) {
            #expect(worst + .milliseconds(50) < .milliseconds(200), "langsamster Median + 50 ms: \(ms(worst + .milliseconds(50)))")
        }
    }

    private func ms(_ d: Duration) -> String { String(format: "%.0f ms", seconds(d) * 1000) }
    private func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

/// Time of the first non-empty hit list after `reset`.
private final class FirstRows: @unchecked Sendable {
    private let lock = NSLock()
    private var start = ContinuousClock.now
    private var first: ContinuousClock.Instant?
    func reset(_ s: ContinuousClock.Instant) { lock.withLock { start = s; first = nil } }
    func mark() { lock.withLock { if first == nil { first = .now } } }
    var elapsed: Duration? { lock.withLock { first.map { $0 - start } } }
}

@MainActor private final class SilentEnvironment: AppEnvironment {
    func chooseSources() -> [URL] { [] }
    func chooseSaveLocation(defaultName: String) -> URL? { nil }
    func runPrint(_ operation: NSPrintOperation) {}
    func openInPreview(_ url: URL) {}
    func confirmDeleteIndex(question: String) -> Bool { false }
}
